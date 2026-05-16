---
layout: default
title: Tool Context Policy
description: Tool-aware policy selectors, loop thresholds, receipts, and trust boundaries.
---

# Tool Context Policy

Wardwright normalizes request-visible tool facts before policy planning,
receipts, history, or UI projection consume them. The active prototype supports
OpenAI-compatible `tools`, `tool_choice`, assistant `tool_calls`, and `tool`
result messages by default. `metadata.tool_context` is accepted only from
trusted gateway paths such as localhost, prototype access, or requests carrying
the configured Wardwright admin token.

Tool policy is not a separate runtime or a replacement for ordinary behavioral
policy. It is one matcher dimension inside the same policy plan:

```text
state scope + lifecycle phase + tool context + caller/session/history -> action
```

Most policies use the default one-state state machine, named `active`. In that
case a tool rule simply says "when this tool context appears, take this ordinary
policy action." The target contract allows a more stateful policy to add
`state_scope` later without changing what tool context means.

## Tool Lifecycle

Tool calls are not one uniform event. Wardwright uses phase names so policy and
UI can explain which part of the tool workflow is being governed:

- `planning`: a request declares available tools, forces `tool_choice`, or the
  model emits an assistant `tool_calls` item. This is the common "model wants a
  local agent/runtime to call a tool" case.
- `argument_repair`: a model call is producing or repairing arguments for a
  known tool schema. This is where stricter JSON/schema routing often belongs.
- `result_interpretation`: a later request includes a `tool` result message and
  the model is summarizing it, validating it, or choosing the next action.
- `loop_governance`: policy counts repeated equivalent tool facts in recent
  history, usually by session/run first and broader scopes only after durable
  privacy rules exist.
- `unknown`: Wardwright saw tool-like facts but cannot confidently classify the
  phase.

Provider-hosted tools such as built-in web search complicate this model. Some
providers return explicit events for hosted tools; for example OpenAI Responses
can include `web_search_call` output items, and Anthropic streams
`server_tool_use` / `web_search_tool_result` blocks for server-side search. If
Wardwright sees those events, it can normalize them as provider-attested tool
facts. If a provider performs internal tool work without exposing events or
usage details, Wardwright can only govern the pre-call route/provider/tool
configuration and the final visible response; it cannot inspect or stop each
hidden internal step.

Tool-aware governance currently has two built-in rule shapes:

- `tool_selector` matches normalized tool context and emits ordinary policy
  actions such as `restrict_routes`, `switch_model`, `reroute`, `block`,
  `annotate`, or `alert_async`.
- `tool_loop_threshold` counts repeated normalized tool facts in bounded policy
  history and emits ordinary policy actions when the threshold fires.

Receipts expose normalized `request.tool_context`, `decision.tool_context`,
`decision.tool_policy_selectors`, and `final.tool_policy` when relevant. Receipt
summaries can filter by tool namespace, name, phase, risk class, source, call
ID, and tool-policy status.

## Composition Examples

The simplest tool-specific rule works in the default `active` state and only
narrows behavior for one tool family:

```yaml
governance:
  - id: github-write-planning
    kind: tool_selector
    action: switch_model
    target_model: managed/write
    tool:
      namespace: mcp.github
      name: create_pull_request
      phase: planning
      risk_class: write
```

Ordinary behavioral policy can sit beside that rule without knowing about
tools:

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

Those rules compose because both emit ordinary route/policy effects. A request
that mentions private context and plans a GitHub write tool may need conflict
arbitration if the rules constrain routes differently; otherwise they can be
reviewed as independent facets.

The target stateful contract adds state as another explicit scope, not as a
nested policy tree:

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

The current runtime already supports tool facets, phase facets, reads, writes,
effects, and conflict findings in projection data. The UI should present state
scope the same way once the engine enforces state-scoped rules. Users can keep
tool policy separate from broader behavior by giving it narrow tool matchers, or
intentionally compose it with route gates, stream guards, structured-output
rules, and alert rules.

The detailed boundary is recorded in
[`contracts/tool-context-policy-contract.md`](https://github.com/bglusman/wardwright/blob/main/contracts/tool-context-policy-contract.md).

## Provider References

- [OpenAI web search](https://developers.openai.com/api/docs/guides/tools-web-search)
  exposes hosted search through Responses API tool configuration and
  `web_search_call` output items.
- [Anthropic web search](https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool)
  exposes server-side search configuration plus `server_tool_use` and
  `web_search_tool_result` response blocks.
