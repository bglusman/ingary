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

The detailed boundary is recorded in
[`contracts/tool-context-policy-contract.md`](https://github.com/bglusman/wardwright/blob/main/contracts/tool-context-policy-contract.md).
