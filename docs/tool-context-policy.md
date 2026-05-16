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
policy action." A more stateful policy can add `state_scope` without changing
what tool context means.

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

Tool-aware governance currently has three built-in rule shapes:

- `tool_selector` matches normalized tool context and emits ordinary policy
  actions such as `restrict_routes`, `switch_model`, `reroute`, `block`,
  `annotate`, or `alert_async`.
- `tool_loop_threshold` counts repeated normalized tool facts in bounded policy
  history and emits ordinary policy actions when the threshold fires.
- `tool_sequence` evaluates ordered relationships between scoped tool/state
  facts. It can transition policy state after a matched tool event, or apply a
  later action when an `after` event is still inside the configured window and no
  `until` reset has occurred.

Those rule shapes cover current-event matching, repeated-tool counting, and a
first pass at ordered sequence control. The sequence implementation deliberately
uses explicit state/window predicates so authors can see why a later tool was
blocked.

Receipts expose normalized `request.tool_context`, `decision.tool_context`,
`decision.tool_policy_selectors`, and `final.tool_policy` when relevant. Receipt
summaries can filter by tool namespace, name, phase, risk class, source, call
ID, and tool-policy status.

## Sequence Policy

Searchable history is the foundation for sequence control. Sequence-aware policy
makes ordering, scope, windows, and reset conditions first-class:

- `after`: a prior tool event that must have occurred. Prior-state and receipt
  predicates are useful future extensions, but are not sequence starters yet.
- `before`: the later/current event facet that is being governed, usually
  expressed as `then.tool` when the rule also names an action.
- `within`: the turn, event-count, or wall-clock window where the prior event is
  still relevant.
- `until`: the state transition or tool event that clears the condition.
- `cache_scope`: the caller/session/run boundary that owns the sequence.
- `then`: the ordinary policy action applied when the later tool facet appears.

Example:

```yaml
state_machine:
  initial_state: active
  states:
    - id: active
    - id: reviewing_untrusted_tool_result

governance:
  - id: enter-untrusted-review
    kind: tool_sequence
    after:
      tool:
        namespace: browser
        phase: result_interpretation
    within:
      turns: 1
    transition_to: reviewing_untrusted_tool_result

  - id: block-shell-while-reviewing
    kind: tool_selector
    state_scope: reviewing_untrusted_tool_result
    action: block
    tool:
      namespace: shell
      risk_class: irreversible
      phase: planning
```

The current runtime supports this scoped shape for tool facts and policy-state
facts. It is still intentionally narrow: windows are recent event/turn windows,
state is represented by the latest scoped `policy_state` fact, and raw tool
payloads stay out of history. Multiple independent state machines in the same
session should use disjoint state names for now; a future `state_machine_id`
facet should make that isolation explicit.

## Problems To Validate

These are the concrete problem hypotheses tool-aware policy should help test.
They are not all proven product value yet; each should be evaluated with
simulation, receipts, and eventually live traces.

### Write-Tool Hardening

Problem: a coding or ops agent may safely use read-only tools most of the time,
then suddenly prepare a write-capable action such as `github.create_pull_request`,
`filesystem.write`, `database.migrate`, `calendar.create_event`, or
`shell.exec`. OWASP classifies unchecked autonomy as excessive agency, and
insecure plugin/tool design can turn untrusted inputs into severe downstream
effects.

Tool policy hypothesis: keep the same public synthetic model, but attach stricter
route, schema, audit, or approval rules only when the tool context implies write
or external side effects.

Example:

```yaml
governance:
  - id: high-risk-write-tools
    kind: tool_selector
    action: switch_model
    target_model: managed/strict-json
    attach_policy_bundle: write_tool_validation_v1
    tool:
      risk_class: write
      phase: planning
```

Falsify it if strict routing rarely catches malformed or risky arguments, adds
too much latency, or policy authors cannot predict when it fires.

### Prompt-Injection Containment

Problem: browser, email, document, and MCP tools pull untrusted content into the
agent loop. Anthropic's computer-use documentation explicitly describes an
agent loop where the application executes tool requests and returns results, and
warns that logged-in/browser use increases prompt-injection risk. Recent MCP
research also reports prompt-injection and tool-poisoning failures across real
AI-assisted development tools.

Tool policy hypothesis: treat result interpretation after untrusted tools as a
distinct phase. Route it through stronger review, block high-risk follow-on
tools, or require a clean planning step before allowing writes.

Example:

```yaml
governance:
  - id: browser-result-before-write
    kind: tool_selector
    action: restrict_routes
    routes: ["managed/injection-aware"]
    tool:
      namespace: browser
      phase: result_interpretation

  - id: no-shell-after-untrusted-page
    kind: tool_selector
    action: block
    tool:
      namespace: shell
      risk_class: irreversible
      phase: planning
```

The second rule is intentionally shown as a tool facet, not the full sequence
condition. In a stateful policy, the UI should compile "after untrusted page
result" into a post-result state or a bounded session-history predicate, then
apply the shell facet inside that state.

Falsify it if result-phase routing does not reduce bad follow-on tool proposals,
or if the policy cannot distinguish malicious instructions from legitimate page
content well enough to help.

### Tool Loop And Cost Control

Problem: tool-capable agents can loop on search, browser, shell, or API calls,
causing cost, latency, rate-limit, or operational noise. Provider docs for
computer use recommend explicit iteration limits. Hosted web search tools expose
provider-side controls such as domain filters, and some providers expose search
use caps such as `max_uses`.

Tool policy hypothesis: normalized tool facts make repeated tool attempts
visible in receipts and allow session/run-scoped budgets without hard-coding
logic into every agent.

Example:

```yaml
governance:
  - id: repeated-searches
    kind: tool_loop_threshold
    action: switch_model
    target_model: managed/diagnostic
    threshold: 4
    cache_scope: session_id
    tool:
      namespace: provider.web_search
      phase: planning
```

Falsify it if loops are better controlled entirely by provider-native `max_uses`
or by the application runtime, with no added value from Wardwright receipts or
simulation.

### Provider-Hosted Tool Visibility

Problem: some tools run inside the provider backend, such as hosted web search
or file search. When providers expose events like OpenAI `web_search_call` or
Anthropic `server_tool_use` / `web_search_tool_result`, Wardwright can normalize
those facts. When the provider hides internal tool steps, Wardwright cannot
inspect or interrupt them.

Tool policy hypothesis: provider capability records should declare which hosted
tool events are visible, which controls can be set pre-call, and which parts are
opaque. The UI can then show "controllable", "observable", and "opaque" tool
regions instead of pretending all tool use is equally governable.

Falsify it if most high-value hosted tools expose too little event data for
receipts or simulation to improve operator decisions.

### Least-Privilege Tool Surfaces

Problem: agents often receive a broad tool list because it is easier than
building a per-step tool surface. Tool-risk research describes both excessive
agency, where agents retain unnecessary permissions, and insufficient agency,
where missing needed tools hurts task completion.

Tool policy hypothesis: tool context plus state/phase facets can compile a
narrower tool surface for each step while preserving the same model contract.
The operator should be able to compare "all tools available" versus
"phase-scoped tools only" in simulation.

Falsify it if narrowed tool surfaces break too many legitimate workflows, or if
authors cannot understand why a tool was unavailable at a given step.

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

- [OWASP Top 10 for LLM Applications](https://owasp.org/www-project-top-10-for-large-language-model-applications/)
  includes prompt injection, insecure plugin design, excessive agency, and
  related risks for LLM applications.
- [OpenAI web search](https://developers.openai.com/api/docs/guides/tools-web-search)
  exposes hosted search through Responses API tool configuration and
  `web_search_call` output items.
- [Anthropic web search](https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool)
  exposes server-side search configuration plus `server_tool_use` and
  `web_search_tool_result` response blocks.
- [Anthropic computer use](https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool)
  describes the agent loop and security concerns around logged-in/browser
  environments.
- [AgenTRIM: Tool Risk Mitigation for Agentic AI](https://arxiv.org/abs/2601.12449)
  frames tool-driven agency risks and proposes per-step least-privilege tool
  access.
- [Are AI-assisted Development Tools Immune to Prompt Injection?](https://arxiv.org/abs/2603.21642)
  studies prompt-injection and tool-poisoning risks across MCP clients.
