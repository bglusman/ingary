---
layout: default
title: Wardwright Policy Engine MVP
description: Initial target use cases, data scopes, and policy execution phases for Wardwright.
---

# Policy Engine MVP

Wardwright's policy system should be designed from concrete agent failures, not
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

The user experience should be visual, conversational, and simulation-first. The
deterministic policy artifact is the storage and review format, not the primary
interface. Operators should be able to describe the behavior they want, let an
AI-assisted authoring flow draft a rule, inspect the compiled policy graph, run
generated simulations, and approve the exact artifact before activation.

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
   - Current implementation supports `restrict_routes`, `switch_model`, and
     `reroute` as planner constraints recorded in receipts as
     `policy_route_constraints`.

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
   - Asynchronous human/operator alerts live here unless an earlier phase
     explicitly returned a blocking approval action.

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
rule fires before release, Wardwright can drop, rewrite, retry, or escalate without
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

Wardwright should adapt the best parts of those systems while making the promise
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

The current BEAM prototype implements the first narrow stream-policy foothold:
mock stream chunks can be checked against literal or regex rules before release,
rewritten or dropped, or blocked before any SSE bytes are sent. Receipts record
the stream policy action, trigger count, trigger events, and whether content was
released to the consumer. Full retry orchestration, real provider stream
holdback, and chunk-boundary spanning are still future work.

## State Scopes

Some policies need history, but not all history belongs in every policy call.
Policy definitions should declare state requirements so Wardwright can avoid
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
success without turning Wardwright into a full observability warehouse.

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

1. Expose the general Wardwright read API to policy code.
2. Expose a bounded policy facts API backed by receipts, counters, and indexes.
3. Expose a Wardwright-API-shaped query facade backed only by configured policy
   caches and ring buffers.

The third approach is probably the best ergonomic compromise. Policy authors
can use query shapes that resemble the ordinary Wardwright read API, but the policy
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
they need. Wardwright can then decide what to track, how to index it, and how to
expose it to the policy engine.

Policies that enforce behavior need a stronger cache contract than policies
that merely annotate receipts. Wardwright should distinguish two classes:

- **deterministic policy working sets**: used for `block`, `reroute`, `retry`,
  `require_human_approval`, rate-limit, and other enforcement actions.
- **best-effort observability caches**: used for UI context, analytics,
  non-blocking annotations, and exploratory policy experiments.

MVP should use deterministic policy working sets for enforcement. If a record is
inside the configured window, it must be visible to the policy query. If it is
outside any configured eviction dimension, it must not be visible. No approximate
LRU, probabilistic summaries, background-lag surprises, or "maybe still in
cache" behavior should affect enforcement decisions.

Deterministic eviction can still be configurable, but the semantics need to be
simple:

- `max_age_seconds`: evict anything older than the cutoff.
- `max_items`: keep the newest N records in a stable ordering.
- `max_bytes`: keep newest records while total retained encoded size is under
  the limit.
- combinations use intersection semantics: a record must satisfy every bound to
  be visible.

That gives policy authors a predictable rule: inside every configured bound
means visible; outside any configured bound means invisible. If that proves too
hard to guarantee efficiently, MVP should prefer fewer supported eviction modes
over best-effort behavior in enforcement paths.

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
      eviction:
        deterministic: true
        order: newest_first
        max_items: 50
        max_age_seconds: 1800
        max_bytes: 262144
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
time window, and fields. The call can look like a normal Wardwright query without
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
outside the configured cache, Wardwright should return an explicit "not available"
policy fact rather than silently scanning durable history.

For observability-only caches, Wardwright may later allow approximate or
best-effort eviction. Those caches must be labeled as such and should not be
available to actions that change model behavior.

## Action Model

Initial actions should be small and composable:

- `allow`
- `annotate_receipt`
- `alert`
- `inject_reminder`
- `retry_with_reminder`
- `reroute`
- `restrict_routes`
- `switch_model`
- `block_final`
- `require_human_approval`

Actions should be phase-limited. For example, `block_final` is legal during
`output.finalizing`, while `reroute` is legal during `route.selecting` or after
a failed stream/output attempt, but not after bytes have already been released
in pass-through mode.

`alert` and `require_human_approval` must not be treated as synonyms:

- `alert` records an event and sends an asynchronous notification sink. It can
  run after the result is returned and should never imply that Wardwright waited for
  a human response.
- `require_human_approval` pauses or defers the request, persists resumable
  state, waits for approve/edit/reject, and needs timeout and idempotency rules.
  That action is a later feature unless we intentionally build a resumable
  request lifecycle.

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

## Rule Composition And Arbitration

Governance rules should not be one unordered bag of effects. Wardwright should
separate rule evaluation from action arbitration:

1. **Detectors** inspect phase inputs and emit proposed actions. Literal,
   regex, parser, route, metadata, counter, and cache checks can usually run in
   parallel because they are pure reads.
2. **Arbiters** combine proposed actions into a single deterministic phase
   decision. Any action that mutates a request, route, stream, retry state, or
   final output must pass through arbitration.

Every rule should declare an effect set:

```yaml
id: no-deprecated-client
phase: response.streaming
match:
  regex: "OldClient\\("
mode:
  type: buffered_horizon
  holdback_bytes: 4096
action:
  type: retry_with_reminder
  reminder: "Do not use OldClient. Use NewClient instead."
  max_retries: 1
once_per:
  scope: session
effects:
  reads: [stream.window, session.triggered_rules]
  writes: [attempt.retry, request.system_reminder]
priority: 50
```

Validation should classify rule interactions before activation:

- **parallel-safe**: detectors have no writes, or only write independent
  annotations and alerts.
- **ordered**: multiple rules may propose compatible but ordered effects, such
  as two candidate retries. These require explicit priority or a named
  arbitration strategy.
- **conflicting**: actions make incompatible promises, such as one rule needing
  pass-through streaming while another requires non-release guarantees for the
  same span.
- **ambiguous**: overlapping rewrites, competing reminders, or route overrides
  that need user confirmation before they can run.

The UI should surface those classes directly. If a policy can run detectors in
parallel and arbitrate safely, it should say so. If a policy depends on order,
priority, or conflict resolution, the user should see that before activation.

## AI-Assisted Authoring

Wardwright should include a policy-authoring assistant that uses an operator-
selected backing model to help draft, explain, review, and refine governance
rules. This assistant is not the runtime policy engine. It proposes artifacts;
the compiler, validator, simulator, and human review path remain authoritative.

The assistant should support:

- translating plain-language intent into a draft governance artifact
- asking clarifying questions when intent is underspecified
- explaining latency, release, retry, and conflict tradeoffs
- generating adversarial examples and expected outcomes
- reviewing diffs between draft and active policy versions
- summarizing compiled behavior in plain language
- proposing fixes when generated simulations find counterexamples

Because the assistant may use the user's configured provider credentials, every
assistant run should make model choice and data sharing explicit:

- ask permission before sending policy text or examples to a provider
- allow local models such as Ollama when configured
- never send provider credentials, hidden config, or raw private receipts unless
  the user explicitly includes them
- record assistant provenance on drafts: model ID, prompt template version,
  timestamp, and whether the user approved the result

The storage artifact should be deterministic YAML or TOML that can be reviewed,
diffed, signed, and activated. Advanced users can edit it directly, but normal
users should work through the assistant, graph, simulator, and review UI.

## Simulation And Generated Tests As UX

Simulation should be a first-class policy authoring surface, not only a CI test.
For each draft rule, Wardwright should generate examples and counterexamples that
make the policy's promise visible.

The current dependency choice keeps `StreamData` in the test profile, but it is
worth an explicit production experiment. StreamData-style constrained generators
could be useful for simulation when the operator wants bounded, reproducible
scenario space: regex near-misses, chunk boundaries, cache-window edges,
metadata combinations, and policy conflict cases. That is different from
live-LLM scenario generation, which is better for realistic language and
unexpected adversarial phrasing. Wardwright should compare three generator
shapes before promoting any test library into production:

- a small internal deterministic generator DSL for stable UI simulations
- StreamData-backed generators available only inside a carefully bounded
  simulation service
- live-LLM-generated scenarios that are normalized into deterministic fixtures
  before they become regression evidence

The product constraint is that generated scenarios must be explainable,
replayable, and pin-able. If a production generator cannot provide stable seeds,
clear shrink/counterexample output, and bounded runtime, it should remain a
development tool rather than part of the policy-authoring UI.

For TTSR rules, generated cases should include:

- trigger split across stream chunks
- trigger at the holdback boundary
- near-miss strings that must not trigger
- multiple matching rules in the same stream
- retry output that violates the same rule again
- Unicode or multibyte boundary cases
- pass-through or too-small-horizon configurations that cannot promise
  non-release

The UI should show generated checks as user-readable evidence:

- which properties passed
- which counterexample failed
- the minimal stream/chunk sequence that demonstrates the failure
- the exact receipt events that would be recorded
- whether violating bytes reached the consumer

Users should be able to pin a generated counterexample as a regression fixture.
That creates a direct loop: describe policy, compile artifact, simulate, inspect
counterexample, revise, and activate only when the behavior matches intent.

## Code-First Policy Visualization

Programmable policy does not automatically make simulation harder. It makes
pre-execution explanation harder unless the host exposes a constrained policy
API and enough trace data to connect source code to runtime behavior.

Wardwright should evaluate two authoring MVPs in parallel:

1. **Structured primitives first**: policy authors compose built-in detectors,
   counters, stream guards, route switches, and arbiters. The UI can visualize
   the rule graph before simulation because the policy shape is explicit.
2. **Starlark-first / code-first**: policy authors write small deterministic
   policy functions against the same ABI. The UI visualizes syntax structure,
   source spans, execution traces, scenario deltas, and opaque branches instead
   of pretending it can statically understand arbitrary code perfectly.

The Starlark-first UI should project code into a policy-shaped graph:

- functions and entrypoints
- branches and conditions
- calls to the Wardwright policy host API
- cache reads, route mutations, stream actions, final-output actions
- declared or inferred effects such as `reads_cache`, `switches_model`,
  `retries_stream`, and `blocks_output`
- unknown or opaque subtrees that cannot be safely classified

Simulation then overlays execution evidence onto that projection:

- which branches evaluated true or false
- which cache counts, regex matches, and stream windows drove a decision
- which source spans produced each action
- which scenarios differ between two policy versions
- which generated counterexamples are now pinned as regressions

Implementation options should be chosen for the layer being tested:

- `go.starlark.net/syntax` is a strong first parser for AST-to-policy-graph
  prototyping because it exposes a Starlark parser, AST nodes, and walking API.
- Rust `starlark` / `starlark_syntax` is the natural runtime-aligned parser if
  Rust owns policy execution.
- `tree-sitter-starlark` is useful for editor-grade concrete syntax,
  highlighting, source spans, and incremental UI feedback.
- Python `ast` can be a fast exploratory parser for a Starlark-like subset, but
  it must reject unsupported Python nodes and must not become the activation
  validator because Python accepts syntax and semantics Starlark should reject.

The decisive comparison is not expressiveness. Programmable policy will always
be more expressive. The product question is whether a technical policy author
can predict, review, and debug behavior faster with structured primitives or
with code plus AST/trace visualization.
