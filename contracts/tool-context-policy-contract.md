# Tool Context Policy Contract

Status: v1 prototype implemented in the BEAM app

Wardwright currently treats session and run as the main hot policy scopes. Tool
calls cut across those scopes: the same synthetic model may need stricter,
cheaper, more auditable, or more capable behavior when it is being used to plan,
execute, repair, or interpret a particular tool invocation.

This contract records the proposed normalized boundary. It is intentionally
provider-neutral. OpenAI-compatible requests, Anthropic-style tool blocks, MCP
tool calls, and future agent runtimes should all lower into this shape before
policy, route planning, receipts, or projection logic depend on tool semantics.

## Goals

- Let one public synthetic model select different policy bundles by tool
  context without changing the client-visible model ID.
- Make tool-related policy decisions visible in receipts and simulation output.
- Support tool-scoped history across sessions without giving policy code
  arbitrary receipt queries.
- Keep tool recognition at the request boundary, not scattered through route,
  policy, receipt, and UI modules.
- Preserve provider compatibility: provider-specific tool payloads may remain in
  the request body, but core policy sees normalized facts.

## Non-Goals

- Wardwright does not execute tools in this spike. It classifies model calls and
  tool-result messages that pass through the model gateway.
- Wardwright does not store raw tool arguments or raw tool results by default.
  Hashes, schemas, status, and redacted summaries are the default receipt facts.
- Tool context is not a replacement for caller provenance. Tenant, application,
  agent, user, session, and run still bound access and retention.

## Tool Call Lifecycle

Model calls can relate to tools in different ways:

1. **Tool planning**: the model is selecting whether to call a tool and with
   which arguments. Signals include declared tools, `tool_choice`, or an agent
   metadata hint such as `intended_tool`.
2. **Tool argument repair**: the model is being asked to produce or repair
   arguments for a specific tool schema.
3. **Tool result interpretation**: the request contains a tool result from a
   prior step and the model is summarizing, validating, or deciding the next
   action.
4. **Tool loop governance**: the policy needs recent equivalent tool facts,
   usually keyed by tool name, argument hash, result hash, status, run/session,
   and optional broader scopes.
5. **Tool approval or escalation**: a future workflow may require resumable
   approval before an irreversible or high-risk tool call proceeds. That is a
   separate approval-gate product surface, but it needs the same tool facts.

These stages should be explicit in a `tool_context.phase` enum. A model call can
have zero, one, or many tool facts, but one primary tool context should be chosen
for policy selection when possible.

## Normalized Shape

```yaml
tool_context:
  schema: wardwright.tool_context.v1
  phase: planning | argument_repair | result_interpretation | loop_governance | unknown
  primary_tool:
    namespace: mcp.github
    name: create_pull_request
    display_name: Create pull request
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

The `namespace` should be stable within a deployment and collision-resistant
across connectors. MCP server name plus tool name is a natural first form.
Provider function names alone are not sufficient when different systems expose
similar names such as `search`, `query`, or `run`.

## Policy Selection

Synthetic model versions should be able to declare policy selectors that refine
the baseline model policy:

```yaml
policy_selectors:
  - id: github-write-tools
    when:
      tool:
        namespace: mcp.github
        risk_class: write
        phase: planning
    attach_policy_bundle: github_write_planning_v3
    route_constraints:
      require_capability: tool_argument_strict_json
      disallow_targets: [local_untrusted]

  - id: browser-read-tools
    when:
      tool:
        namespace: browser
        risk_class: read_only
    attach_policy_bundle: browser_observation_v1
    route_constraints:
      prefer_targets: [cheap_fast]
```

Selectors are ordered only for conflict arbitration. They should compile into a
typed policy plan so runtime execution can answer:

- which selector matched
- which policy bundle was attached
- which route constraints changed
- which tool facts were read
- why a selector did not match when a reviewer expected it to

The same public `model` can therefore behave differently for the same caller and
session depending on whether the model call is preparing a database migration,
reading a file, summarizing a web page, repairing JSON arguments, or interpreting
a failed tool result.

## State Scopes

Tool policy needs scopes that are broader than one request but narrower than
arbitrary global memory:

| Scope | Use | Risk |
|---|---|---|
| `attempt` | argument validation and structured repair | low persistence value |
| `run` | repeated equivalent calls during one agent run | safest first loop detector |
| `session` | session-local tool spam, repeated failures, cost windows | current natural runtime owner |
| `caller_tool` | cross-session policy for one agent/tool pair | valuable for recurring failures |
| `tenant_tool` | abuse, budget, and high-risk tool governance | needs explicit privacy and retention |

The first implementation should support `run` and `session` hot counters, then
add `caller_tool` only after the storage contract can query bounded tool facts
without exposing raw arguments or results.

## Receipts

Receipts should preserve the tool-policy decision without storing private tool
payloads by default:

```yaml
decision:
  tool_context:
    phase: planning
    primary_tool:
      namespace: mcp.github
      name: create_pull_request
      risk_class: write
      source: declared_tool
    confidence: exact
  tool_policy_selectors:
    - id: github-write-tools
      matched: true
      attached_policy_bundle: github_write_planning_v3
      route_constraints: [require_capability:tool_argument_strict_json]
final:
  tool_policy:
    status: allowed | transformed | rerouted | blocked | alerted
    state_scope: session
    counter_key_hash: sha256:...
    threshold: 3
    observed_count: 4
```

Receipt search should eventually filter by normalized tool namespace, tool name,
phase, risk class, selector id, and tool-policy status.

## Simulation And Projection

Policy projections should show tool selectors as first-class nodes before the
attached policy bundle. Simulation scenarios should include:

- tool planning with one exact tool choice
- ambiguous tool names across namespaces
- argument repair with invalid JSON followed by valid JSON
- repeated equivalent tool calls in one run
- repeated failures across sessions for the same caller/tool pair
- read-only tool use where strict write-tool policy does not fire
- privacy checks proving raw arguments and results are not stored when capture
  is disabled

Generated tests should assert behavior and receipt fields: selected model,
attached policy bundle, route constraints, threshold status, and redacted tool
facts. They should not assert internal parser branches.

## Implemented V1

The active BEAM app now implements the first useful slice of this contract:

- `Wardwright.ToolContext` normalizes trusted `metadata.tool_context`,
  OpenAI-compatible `tools`, `tool_choice`, assistant `tool_calls`, and `tool`
  result messages into `wardwright.tool_context.v1`.
- `Wardwright.Policy.History.record_tool_context/2` records bounded
  `tool_context` events in the existing ETS-backed policy cache. Cache keys use
  `namespace:name:phase`; values keep tool identity, phase, status, and hashes,
  not raw arguments or raw results.
- Governance rules can use `kind: tool_selector` to attach selector evidence and
  emit ordinary policy actions such as `restrict_routes`, `switch_model`,
  `reroute`, `block`, `annotate`, or `alert_async`.
- Governance rules can use `kind: tool_loop_threshold` to count repeated
  normalized tool facts in a bounded caller scope and then emit ordinary policy
  actions.
- Receipts include normalized `request.tool_context`,
  `decision.tool_context`, `decision.tool_policy_selectors`, and
  `final.tool_policy` when relevant.
- `/v1/receipts` summaries can filter by `tool_namespace`, `tool_name`,
  `tool_phase`, `tool_risk_class`, and `tool_policy_status`.

The implementation deliberately reuses the existing policy-plan, route
constraint, receipt, and bounded policy-cache boundaries. It does not add a
separate tool runtime or tool executor.

## Implementation Path

1. Add projection and LiveView review nodes for selector match/miss evidence.
2. Add argument-aware risk refinement for tools whose read/write behavior
   depends on arguments.
3. Add durable `caller_tool` queries after storage can expose bounded tool facts
   without raw payload leakage.
4. Only then consider cross-session `caller_tool` and `tenant_tool` durable
   queries.

## Open Questions

- Should clients be allowed to supply `metadata.tool_context`, or should that be
  accepted only from trusted gateways? Header/body trust rules should mirror
  caller provenance.
- How should Wardwright classify tools whose risk changes by arguments, such as
  a file tool that can read or write?
- Should policy selectors attach whole bundles, toggle rules inside an existing
  bundle, or produce actions like any other policy rule?
- What is the minimum namespace registry needed for MCP servers, local tools,
  provider-native tools, and app-specific tool names?
- How much cross-session tool memory is useful before privacy, retention, and
  consent dominate the product value?

## Research Notes

- OpenAI Chat Completions exposes tool availability and tool forcing through
  `tools` and `tool_choice`, assistant-generated `tool_calls`, and `tool`
  messages linked by `tool_call_id`.
- Anthropic represents tool use with `tool_use` and `tool_result` content blocks
  rather than OpenAI's `tool` role.
- MCP models tools as server-exposed capabilities invoked through a `tools/call`
  request. That makes MCP server/tool namespace a good candidate for
  Wardwright's normalized tool identity.
