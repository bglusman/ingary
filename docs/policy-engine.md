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
