# Tool Context Policy Contract

Status: implemented prototype

Wardwright normalizes request-visible tool facts before policy planning,
receipts, history, or UI projection consume them. The same public synthetic
model can therefore route or govern differently when a request is planning,
repairing, looping on, or interpreting a tool call.

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

## Receipts And Search

Receipts include normalized tool context on the request and decision, selector
match evidence under `decision.tool_policy_selectors`, and loop-threshold status
under `final.tool_policy` when a threshold fires.

Receipt summaries can filter by `tool_namespace`, `tool_name`, `tool_phase`,
`tool_risk_class`, `tool_source`, `tool_call_id`, and `tool_policy_status`.

## Trust Boundary

`metadata.tool_context` is gateway-attested evidence, not public client input.
Remote callers without the configured admin token cannot drive tool policy from
that field. This is still a prototype trust model: production deployments should
replace the admin-token shortcut with explicit gateway identity, request
signature, or another auditable attestation mechanism.
