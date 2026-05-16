# Tool Context Policy Contract

Status: implemented prototype

Wardwright normalizes request-visible tool facts before policy planning,
receipts, history, or UI projection consume them. The same public synthetic
model can therefore route or govern differently when a request is planning,
repairing, looping on, or interpreting a tool call.

Tool context is a policy dimension, not a separate policy engine:

```text
state scope + lifecycle phase + tool context + caller/session/history -> action
```

The default state scope is the one-state `active` projection. More explicit
state machines may narrow rules by state, but they should not create a separate
nested policy tree for each tool. State-scoped rule enforcement is target
contract behavior; the current runtime projects state machines and tool facets
but does not yet enforce `state_scope`.

## Tool Call Lifecycle

Model calls can relate to tools in different ways:

1. `planning`: the request declares available tools, forces `tool_choice`, or
   the model emits an assistant tool call.
2. `argument_repair`: the model is being asked to produce or repair arguments
   for a known tool schema.
3. `result_interpretation`: the request contains a tool result from a prior
   step and the model is summarizing, validating, or deciding the next action.
4. `loop_governance`: policy needs recent equivalent tool facts, usually keyed
   by tool name, phase, argument hash, result hash, status, and caller scope.
5. `unknown`: tool-like facts exist, but the phase cannot be classified
   confidently.

Provider-hosted tools are visible only when the provider exposes their events or
usage. OpenAI Responses web search can surface `web_search_call` output items.
Anthropic web search can surface `server_tool_use` and
`web_search_tool_result` blocks. If a provider executes a hosted tool without
emitting comparable evidence through Wardwright, policy can still allow, deny,
or route the request before it reaches that provider, but it cannot inspect or
interrupt hidden internal tool steps.

## Normalized Tool Context

`Wardwright.ToolContext` lowers supported request shapes into
`wardwright.tool_context.v1`:

```yaml
tool_context:
  schema: wardwright.tool_context.v1
  phase: planning | argument_repair | result_interpretation | loop_governance | unknown
  primary_tool:
    namespace: mcp.github
    name: create_pull_request
    source: declared_tool | tool_choice | assistant_tool_call | tool_result | caller_metadata | inferred
    risk_class: read_only | write | irreversible | external_side_effect | unknown
    schema_hash: sha256:...
  tool_call_id: call_abc
  available_tools:
    - namespace: mcp.github
      name: create_pull_request
      schema_hash: sha256:...
  argument_hash: sha256:...
  result_hash: sha256:...
  result_status: success | error | timeout | rejected | unknown
  confidence: exact | declared | inferred | ambiguous
```

The prototype supports OpenAI-compatible `tools`, `tool_choice`, assistant
`tool_calls`, and `tool` result messages by default. `metadata.tool_context` is
accepted only when the caller is a trusted gateway path such as localhost,
prototype access, or a request carrying the configured Wardwright admin token.
Raw tool arguments and tool results are not stored by default; hashes are used
for receipts and history evidence.

## Governance Rules

Tool selectors use ordinary policy actions, so they compose with route gates,
alerts, and receipt evidence:

```yaml
governance:
  - id: github-write-tools
    kind: tool_selector
    action: switch_model
    target_model: managed/write
    attach_policy_bundle: github_write_planning_v1
    tool:
      namespace: mcp.github
      name: create_pull_request
      phase: planning
      risk_class: write
```

Rules can also compose with ordinary non-tool behavior:

```yaml
governance:
  - id: private-context-route
    kind: route_gate
    action: restrict_routes
    match: "customer|credential|secret"
    routes: ["local/private"]

  - id: github-write-planning
    kind: tool_selector
    action: switch_model
    target_model: managed/write
    tool:
      namespace: mcp.github
      risk_class: write
      phase: planning
```

The target stateful contract adds state as one more rule facet:

```yaml
state_machine:
  initial_state: observing
  states:
    - id: observing
    - id: repairing_tool_args

governance:
  - id: repair-github-pr-args
    kind: tool_selector
    state_scope: repairing_tool_args
    action: switch_model
    target_model: managed/strict-json
    attach_policy_bundle: strict_tool_argument_repair_v1
    tool:
      namespace: mcp.github
      name: create_pull_request
      phase: argument_repair
```

The compiler and UI should present rule facets directly: state scope, phase,
tool matcher, reads, writes, effects, and conflict findings. The current
projection data already carries phase/tool reads, writes, effects, and conflict
findings; state scope becomes the same kind of facet once runtime enforcement
exists. That keeps simple tool policies simple while still allowing them to
compose with stateful retry or approval flows.

Loop thresholds count normalized tool history within a declared caller scope:

```yaml
governance:
  - id: repeat-github-write
    kind: tool_loop_threshold
    action: switch_model
    target_model: managed/write
    threshold: 2
    cache_scope: session_id
    tool:
      namespace: mcp.github
      name: create_pull_request
```

The first implementation defaults tool-loop history to the existing
session-scoped `tool_call` policy-cache event kind. Cross-session and
tenant-level tool memory should wait for explicit durable storage, privacy, and
retention rules.

## Sequence Policy

The current implementation records normalized tool facts, counts repeated
equivalent tool facts, records scoped policy-state transitions, and can enforce
ordered cross-tool sequences inside bounded history windows.

Cross-tool sequence enforcement means policy over ordered relationships between
different tool facts, state transitions, and time or turn windows. For example,
"after a browser result from untrusted content, block shell or filesystem writes
until a review step succeeds" is a sequence rule. It requires explicit
predicates for:

- `after`: the prior tool event, state, or receipt fact that starts the
  condition.
- `before`: the later/current tool facet that is being governed. The current
  implementation accepts this directly or as `then.tool` when the sequence also
  names an action.
- `within`: the maximum turn count, event count, or wall-clock age where the
  prior fact still matters.
- `until`: the state transition or later tool event that clears the condition.
- `scope`: the caller/session/run boundary for the sequence.
- `then`: the ordinary policy action emitted when the later tool facet appears.

Supported shape:

```yaml
governance:
  - id: untrusted-browser-before-shell
    kind: tool_sequence
    after:
      tool:
        namespace: browser
        phase: result_interpretation
    within:
      turns: 3
    until:
      state: reviewed_untrusted_tool_result
    then:
      action: block
      tool:
        namespace: shell
        risk_class: irreversible
        phase: planning
```

The implementation can also compile a sequence into explicit state transitions
plus state-scoped selectors:

```yaml
governance:
  - id: enter-untrusted-review
    kind: tool_sequence
    cache_scope: session_id
    after:
      tool:
        namespace: browser
        phase: result_interpretation
    transition_to: reviewing_untrusted_tool_result

  - id: block-shell-while-reviewing
    kind: tool_selector
    cache_scope: session_id
    state_scope: reviewing_untrusted_tool_result
    action: block
    tool:
      namespace: shell
      risk_class: irreversible
      phase: planning
```

The first implementation is deliberately bounded: sequence windows are recent
event/turn windows, state is represented by the latest scoped `policy_state`
fact, and raw tool arguments/results remain excluded from history. Multiple
independent state machines in the same scope should use disjoint state names
until a `state_machine_id` facet is added to the runtime contract. The UI should
present the ordered event path, the active window, and the reset condition so the
author can understand why the later tool was allowed or blocked.

## Receipts And Search

Receipts include normalized tool context on the request and decision, selector
match evidence under `decision.tool_policy_selectors`, and loop-threshold status
under `final.tool_policy` when a threshold fires.

Receipt summaries can filter by `tool_namespace`, `tool_name`, `tool_phase`,
`tool_risk_class`, `tool_source`, `tool_call_id`, and `tool_policy_status`.

## Trust Boundary

`metadata.tool_context` is gateway-attested evidence, not public client input.
Remote callers without the configured admin token cannot drive tool policy from
that attestation field. They can still drive ordinary declared/request-visible
tool policy through standard fields such as `tools`, `tool_choice`, assistant
`tool_calls`, and `tool` result messages. This is still a prototype trust
model: production deployments should replace the admin-token shortcut with
explicit gateway identity, request signature, or another auditable attestation
mechanism.
