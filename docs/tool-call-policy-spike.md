---
layout: default
title: Tool-Call-Aware Policy Spike
description: Research spike for selecting route and policy behavior by tool context, not only session context.
---

# Tool-Call-Aware Policy Spike

Wardwright should not treat session as the only meaningful policy grouping for
agentic work. Sessions explain conversational continuity. Tool calls explain
operational intent. For many workflows, "this model call is for a write-capable
GitHub tool" or "this call is interpreting a failed browser result" is more
actionable than "this call belongs to session 123."

The core hypothesis is now implemented as a v1 backend slice: a stable public
synthetic model can attach different selector evidence, route constraints, and
bounded history policy outcomes for the same caller, same session, and same
model ID depending on normalized tool context.

See the companion contract in `contracts/tool-context-policy-contract.md`.

## Why It Matters

Tool context crosses sessions. The same agent may repeatedly use the same
database, browser, GitHub, shell, calendar, or support-ticket tool across many
sessions. That creates policy opportunities that session-local grouping cannot
handle well:

- use stronger argument validation for tools with external side effects
- route planning or argument repair for code-writing tools to models that follow
  schemas better
- use cheaper or lower-latency routes for read-only observation tools
- escalate or block irreversible tools after a threshold
- detect repeated equivalent tool failures across sessions
- compare policy outcomes by tool family rather than by agent run
- produce receipts that explain why a specific tool path got a different model
  or governance bundle

This is especially relevant to Wardwright because the product promise is stable
model contracts backed by route graphs, policy, simulation, and receipts. The
caller should not need to mint `coding-balanced-github-write-strict` just to get
different behavior for one tool family.

## Current Fit

The existing docs already identify tool loops as a policy example, but mostly
as a session/run problem. The broader idea is a control-plane axis:

- **caller provenance** answers who caused the call
- **session/run** answers where it fits in agent execution
- **synthetic model** answers the public contract requested by the client
- **tool context** answers what operational capability the model call is for

Policy selection should be able to use all four axes. Tool context should not be
buried in request metadata or prompt text.

## Candidate Applications

### Write-Tool Hardening

A model call preparing arguments for a write-capable tool can attach stricter
policies than the baseline model:

- require strict JSON/tool-argument schema conformance
- require a second validation pass for destructive arguments
- disallow local or untrusted provider targets when prompts include sensitive
  operational state
- emit receipts with selector, tool name, risk class, and policy bundle

### Read-Only Tool Economy

Read-only observation tools often need fast summarization or extraction rather
than expensive reasoning:

- prefer a cheap model for browser/page observation summaries
- keep route fallback for malformed output or ambiguous success
- alert only after repeated failures, not on every low-risk call

### Tool Result Interpretation

The model call after a tool result often has different risk from the call that
created the tool arguments:

- failed tool result: attach repair, retry-limit, and diagnostic policies
- successful tool result: attach summarization or artifact-verification policy
- partial result: route to a model with stronger ambiguity handling

### Cross-Session Tool Memory

Some signals are only useful across sessions:

- a specific caller repeatedly passes invalid arguments to the same tool
- a tool namespace is producing frequent timeouts
- a write tool is often blocked by policy and needs better authoring guidance
- a cheap route works for one read-only tool but not for another

This should start as bounded, redacted, queryable tool facts, not arbitrary
receipt access from policy code.

## Complications

### Tool Identity Is Not Universal

Provider APIs do not agree on tool representation. OpenAI-compatible requests
can expose `tools`, `tool_choice`, assistant `tool_calls`, and `tool` result
messages. Anthropic uses content blocks. MCP has server-exposed tools invoked
through `tools/call`. Wardwright needs a normalized identity:

```text
namespace + tool name + optional schema hash + risk class
```

Plain function names are not enough. Many tools are named `search`, `query`,
`run`, or `open`.

### Tool Phase Can Be Ambiguous

A request that declares a tool is not necessarily "for" that tool. It may be
choosing among many tools. A request containing a tool result may be interpreting
that result, repairing a failed call, or moving to a different tool. The
contract therefore needs confidence levels: `exact`, `declared`, `inferred`,
and `ambiguous`.

### Risk Can Depend On Arguments

`filesystem.write` is obviously risky, but `filesystem.read` can still expose
private data. A browser tool may be read-only until it can submit a form. Risk
class should support static declarations plus later argument-aware refinement.

### Privacy And Retention

Tool arguments and results may contain user content, credentials, file paths,
customer data, or internal identifiers. The default receipt should store:

- normalized tool namespace/name
- phase and risk class
- schema hash
- argument/result hashes
- redacted summaries only when explicitly enabled

Raw tool payload capture must remain opt-in and retention-bound.

### Selector Conflicts

Two selectors may match the same request: for example `github.write` and
`high_cost_session`. The compiler should treat tool selectors like other policy
nodes with declared reads, effects, priorities, and conflict findings. Runtime
code should not special-case these inside a router branch.

## Implemented V1

The first useful slice is in the BEAM app:

1. Normalize trusted `metadata.tool_context`, OpenAI-compatible `tools`,
   `tool_choice`, assistant `tool_calls`, and `tool` result messages into
   `wardwright.tool_context.v1`.
2. Add `tool_selector` governance rules that match namespace, name, risk class,
   and phase, then emit existing route/block/alert/annotation actions.
3. Add `tool_loop_threshold` governance rules that count bounded ETS history by
   normalized tool key and caller scope.
4. Record selector match evidence, normalized tool context, and tool-policy
   threshold outcomes in receipts.
5. Keep raw tool arguments and raw tool results out of receipts and policy cache
   by default; only hashes are recorded.
6. Add behavior tests proving the same synthetic model can route differently for
   different tool contexts, OpenAI tool fields can drive route constraints,
   repeated tool facts can trigger a bounded history policy, and raw arguments
   are not persisted.

Cross-session durable tool facts should wait until storage can query them
without raw payload leakage.

## Example Scenario

```yaml
synthetic_model: coding-balanced
request:
  model: coding-balanced
  metadata:
    tool_context:
      phase: planning
      primary_tool:
        namespace: mcp.github
        name: create_pull_request
        risk_class: write
expected:
  selected_policy_bundle: github_write_planning_v3
  route_constraints:
    - require_capability: tool_argument_strict_json
  receipt:
    decision.tool_context.primary_tool.name: create_pull_request
    decision.tool_policy_selectors[0].matched: true
```

A second request to the same `coding-balanced` model with
`browser.read_page` should not attach the GitHub write bundle. That is the
behavioral test that proves this is policy selection by tool context, not a new
model alias.

## Product Questions

- Is tool-context policy a feature of synthetic model versions, tenant policy,
  or both?
- Should tool selectors attach policy bundles, route constraints, or ordinary
  policy actions?
- Does a UI user think in terms of "tool families" or individual tool names?
- Which tool namespaces are stable enough to be product-facing?
- How should Wardwright represent tools that are not visible in the model API
  because the agent runtime executes them outside the model call?

## Research References

- OpenAI Chat Completions API: tool availability, `tool_choice`, tool calls, and
  `tool` result messages.
- OpenAI function calling guide: tool use as a multi-step model/application
  conversation.
- Anthropic tool use docs: `tool_use` and `tool_result` content blocks.
- Model Context Protocol tools docs: servers expose tools and clients invoke
  them with `tools/call`.
