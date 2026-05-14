---
layout: default
title: Ingary Policy Engine MVP
description: Initial target use cases, data scopes, and policy execution phases for Ingary.
---

# Policy Engine MVP

Ingary's policy system should be designed from concrete agent failures, not
from a general-purpose scripting fantasy. The first product question is:

> What is the smallest policy model that can prevent, repair, reroute, or make
> visible the failures we actually expect in constrained agent workflows?

The current prototype has a small built-in request policy engine. The next step
is to define the durable execution model that can support request, route,
stream, output, and history-aware policies without adding unbounded overhead to
every synthetic model call.

## Design Bias

Start with declarative and built-in policies for common cases. Add Starlark as
the first advanced portable language only after the execution phases, state
scopes, and action model are stable.

Policy language is less important than the policy ABI:

- what data the policy can see
- when it runs
- how much stream/history it may inspect
- what bounded state it can read/write
- what actions it can return
- how receipts explain the decision

## Initial Use-Case Matrix

| Use case | Policy phase | Required data | Required state | Actions |
|---|---|---|---|---|
| Ambiguous success | output, final | response text, structured fields, expected artifact metadata | current call | alert, block final, annotate receipt |
| Structured output repair | output stream, final | buffered output, parser/schema errors | current attempt | retry with correction, block, annotate |
| Deprecated pattern / TTSR | response stream | bounded stream window, rule match offsets | current attempt | withhold, rewrite, retry with reminder |
| Tool loop / tool spam | request, route, final | tool call name, args hash, result hash, route attempts | run/session | inject reminder, reroute, alert, stop |
| Context/cost budget | request, route, final | token estimate, provider, usage, latency | run/session, optional tenant budget | route, require approval, stop, alert |
| Prompt experiment guardrails | request, final | prompt transform version, route, output verdict | aggregate receipts, not hot path | annotate, compare, rollback candidate |
| Abuse/DOS | request, route | caller identity, rate, concurrent runs, tokens | tenant/user/agent windows | rate-limit, reject, degrade, alert |

MVP should target the first five. Prompt-experiment analytics and DOS controls
should influence the state interface, but they do not need full implementation
before the policy engine becomes useful.

## Execution Phases

Policies should run at explicit phases. Each phase receives only the data it
needs unless the synthetic model asks for more.

1. **request.received**
   - Inputs: normalized request, caller context, metadata, estimated tokens.
   - Useful for prompt transforms, request guards, budget checks.
   - No model output available.

2. **route.selecting**
   - Inputs: request facts, candidate routes, provider health, scoped counters.
   - Useful for route gates, budget-aware routing, model capability checks.
   - May return route overrides or approval requirements.

3. **response.streaming**
   - Inputs: normalized stream events plus bounded ring buffer.
   - Useful for time-travel stream rewriting, regex/literal guards, structured
     partial parsing, early stop/retry.
   - Must have explicit latency and memory budgets.

4. **output.finalizing**
   - Inputs: full or bounded final output, schema/parser verdicts, attempt
     metadata.
   - Useful for structured output repair, ambiguous success detection, final
     block/alert decisions.

5. **receipt.finalized**
   - Inputs: final receipt, policy actions, usage, route attempts.
   - Useful for sinks, analytics, experiments, and non-blocking alerts.
   - Should not mutate the already-returned user result.

## Time-Travel Stream Rewriting

TTSR is best treated as a stream-phase policy mode, not a separate feature.
The operator configures a bounded holdback window:

```yaml
stream_policy:
  mode: buffered_horizon
  holdback_bytes: 4096
  max_added_latency_ms: 250
  rules:
    - id: deprecated-client
      match:
        contains: "OldClient("
      action:
        type: retry_with_reminder
        reminder: "Do not use OldClient. Use NewClient instead."
```

The consumer receives data only after it has passed the holdback horizon. If a
rule fires before release, Ingary can drop, rewrite, retry, or escalate without
letting the violating output reach the consumer.

MVP guardrails:

- bounded ring buffer by bytes/tokens/events
- max policy CPU per stream event
- max policy CPU per attempt
- explicit fail-open/fail-closed setting per synthetic model
- receipt fields for `released_to_consumer`, trigger offset, action, retry count

### Related Real-World Patterns

The exact term "time-travel stream rewriting" does not appear to be a common
public product category. The underlying design space is visible in existing
guardrail systems:

- OpenAI Guardrails describes the tradeoff between non-streaming output checks,
  where guardrails finish before content is shown, and streaming output checks,
  where unsafe content can briefly appear before a guardrail completes.
- TrueFoundry's AI Gateway documents a streaming guardrail mode that buffers
  the complete response, runs output mutation and validation, then streams only
  if the response passes.
- NVIDIA NeMo Guardrails supports streaming output rails with chunk buffering
  and notes that `stream_first` improves time to first token but may already
  have sent objectionable text before a rail triggers.
- Portkey describes output guardrails with `deny` and `retry`, but the public
  docs position them as after-response checks rather than bounded holdback
  stream rewriting.
- Several gateway products either disable output guardrails for streaming or
  require `stream=false`, which is a useful negative example: operators often
  have to choose between low latency and enforcement.

Ingary should adapt the best parts of those systems while making the promise
more explicit:

- `pass_through`: lowest latency; policies observe and can alert, but cannot
  guarantee non-release.
- `chunk_buffered`: validate/mutate chunks before release; bounded latency and
  partial enforcement.
- `buffered_horizon`: maintain a rolling holdback window; content is released
  only after it is outside the risk horizon.
- `full_buffer`: safest; no output reaches the consumer until final validation.

TTSR maps most closely to `buffered_horizon` plus actions such as
`retry_with_reminder`, `rewrite_chunk`, `drop_chunk`, `block_final`, and
`alert`. The receipt must say which mode was active, how many bytes/tokens were
held back, whether violating bytes were released, and which retry or rewrite
action fired.

## State Scopes

Some policies need history, but not all history belongs in every policy call.
Policy definitions should declare state requirements so Ingary can avoid
unnecessary tracking.

| Scope | Examples | MVP? |
|---|---|---|
| `attempt` | current request/output, stream window, parser state | yes |
| `run` | retries, selected routes, repeated model attempts | yes |
| `session` | repeated tool-call hashes across a user session | yes |
| `caller_agent` | per-agent rolling error/cost counters | later |
| `caller_user` | per-user budget and abuse windows | later |
| `tenant` | tenant-wide rate/cost/DOS control | later |
| `global` | marketplace abuse, fleet-level anomaly detection | no |

MVP state should be limited to `attempt`, `run`, and `session`. Those scopes
support loop detection, retry limits, TTSR, structured repair, and ambiguous
success without turning Ingary into a full observability warehouse.

## State API Shape

Policies should not query arbitrary storage. They should receive named,
precomputed facts and scoped counters declared in the model definition.

Example:

```yaml
state_requirements:
  - id: recent_tool_hashes
    scope: session
    kind: rolling_counter
    key: "tool:{name}:{args_hash}:{result_hash}"
    ttl_seconds: 1800
    max_entries: 256
  - id: retry_count
    scope: run
    kind: counter
    key: "route_retry:{synthetic_model}"
```

Policy code then sees:

```json
{
  "state": {
    "recent_tool_hashes": {
      "current_count": 3,
      "window_seconds": 1800
    },
    "retry_count": {
      "current_count": 1
    }
  }
}
```

This keeps policy deterministic and makes cost visible. It also lets the UI
explain why a synthetic model has higher overhead.

## History Access And Metadata

Policy code will sometimes need data outside the current request. Tool-loop
detection needs recent tool attempts in the same run or session. Budget control
may need rolling token spend for a session, agent, user, or tenant. DOS controls
eventually need broader caller windows.

There are three possible designs:

1. Expose the general Ingary read API to policy code.
2. Expose a bounded policy facts API backed by receipts, counters, and indexes.
3. Expose an Ingary-API-shaped query facade backed only by configured policy
   caches and ring buffers.

The third approach is probably the best ergonomic compromise. Policy authors
can use query shapes that resemble the ordinary Ingary read API, but the policy
runtime only serves data that the synthetic model explicitly declared as part of
its hot working set.

Direct access to the full historical `GET` surface is attractive because it is
flexible, but it creates hot-path problems:

- unpredictable latency while a policy query scans history
- nondeterminism if the same policy sees different receipt state on retry
- difficult authorization boundaries for multi-tenant deployments
- easy accidental cross-session or cross-user leakage
- unbounded storage/index requirements because policies may query anything
- harder simulation, replay, and test reproducibility

Instead, model definitions should declare the facts or recent-record caches
they need. Ingary can then decide what to track, how to index it, and how to
expose it to the policy engine.

Example:

```yaml
policy_context:
  cache_mode: explicit
  facts:
    - id: session_recent_tool_calls
      source: receipts
      scope: session
      select:
        event_type: tool_call.finished
        fields: [tool_name, args_hash, result_hash, status]
      window:
        max_age_seconds: 1800
        max_items: 128
    - id: run_retry_count
      source: counters
      scope: run
      key: "retry:{synthetic_model}"
    - id: tenant_token_budget
      source: counters
      scope: tenant
      key: "tokens:{tenant_id}"
      window:
        max_age_seconds: 86400
  recent_records:
    - id: session_receipts
      api: receipts
      scope: session
      max_items: 50
      max_age_seconds: 1800
      fields:
        - receipt_id
        - synthetic_model
        - final.status
        - decision.selected_model
        - final.events
```

The policy input receives only the declared facts and recent-record handles:

```json
{
  "facts": {
    "session_recent_tool_calls": [
      {"tool_name": "browser", "args_hash": "h1", "result_hash": "r1", "status": "ok"},
      {"tool_name": "browser", "args_hash": "h1", "result_hash": "r1", "status": "ok"}
    ],
    "run_retry_count": {"value": 2},
    "tenant_token_budget": {"used": 812340, "limit": 1000000}
  },
  "recent": {
    "session_receipts": {
      "available": 14,
      "max_items": 50,
      "max_age_seconds": 1800
    }
  }
}
```

Advanced policy engines may get a constrained query primitive, but it should be
served from these declared caches/ring buffers and bound by scope, result limit,
time window, and fields. The call can look like a normal Ingary query without
being backed by unbounded historical storage.

For example:

```python
ctx.receipts.list(
    scope = "session",
    where = {"event_type": "tool_call.finished", "tool_name": "browser"},
    limit = 20,
    max_age_seconds = 1800,
)
```

That is different from giving Starlark arbitrary access to `/v1/receipts`.
The query is deterministic, scoped, authorized, served from a bounded cache, and
visible in the synthetic model's overhead estimate. If a policy asks for data
outside the configured cache, Ingary should return an explicit "not available"
policy fact rather than silently scanning durable history.

## Action Model

Initial actions should be small and composable:

- `allow`
- `annotate_receipt`
- `alert`
- `inject_reminder`
- `retry_with_reminder`
- `reroute`
- `block_final`
- `require_human_approval`

Actions should be phase-limited. For example, `block_final` is legal during
`output.finalizing`, while `reroute` is legal during `route.selecting` or after
a failed stream/output attempt, but not after bytes have already been released
in pass-through mode.

## MVP Feature Set

The first real policy engine should ship with:

1. request-phase built-ins for literal/regex match, metadata predicates, and
   prompt transform injection
2. route-phase built-ins for context-window, retry-count, and budget predicates
3. stream-phase buffered horizon with literal/regex match and retry/escalate
4. final-output JSON and XML validation with retry-or-block
5. scoped state for `attempt`, `run`, and `session`
6. receipt events for every policy trigger and action
7. UI visibility into required state, policy phase, action, latency, and whether
   output was released to the consumer

Starlark should initially target the same ABI and scopes. If a use case cannot
be expressed with the ABI, that is a signal to adjust the ABI, not to give the
policy language direct storage or network access.
