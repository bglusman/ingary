---
title: Structured-Output Governor Contract
description: Historical visible contract for the structured-output bakeoff.
---

# Structured-Output Governor Contract

This is the visible implementation contract for the structured-output bakeoff.
Agents may read this document and translate it into native tests. The final
Python backend oracle is held out and is run externally after implementation.

The implementation attempt is timeboxed. Use a 30 minute default agent timeout
for the first rerun unless the harness shows that is too short for all
backends. The work is tiered:

- Core behavior must be completed first. A backend that skips core scenarios to
  chase advanced scenarios should score poorly even if the advanced work is
  interesting.
- Advanced differentiators should be attempted only after core native tests are
  passing. They are in scope for scoring, but partial completion is acceptable
  inside the timebox and should be reported explicitly.

## Goal

Implement non-streaming structured-output governance for a synthetic model. A
request may receive malformed, schema-invalid, or semantically invalid provider
output. The governor must treat those failures as non-terminal guard events
while budget remains, retry with validation feedback, and return the first valid
response that satisfies the configured schema and semantic rules. When the
guard budget is exhausted, the governor must fail closed and preserve a receipt
that explains the attempted path.

Streaming governance is out of scope for this bakeoff unless the implementation
explicitly records it as an extra capability.

## Public Test Configuration

The prototype test API may accept a dynamic config containing:

- `synthetic_model`: the externally requested model alias
- `targets`: one or more provider model targets
- `structured_output.schemas`: named JSON schemas
- `structured_output.schema_rule_id`: rule id recorded for JSON syntax and
  schema validation failures; use `structured-json` for this bakeoff
- `structured_output.semantic_rules`: semantic validators applied after schema
  validation
- `structured_output.guard_loop.max_attempts`: total provider attempts allowed
- `structured_output.guard_loop.max_failures_per_rule`: per-rule failure budget
- `structured_output.guard_loop.on_violation`: expected retry action
- `structured_output.guard_loop.on_exhausted`: expected terminal action
- `test_provider.kind = canned_sequence`: deterministic provider outputs used
  by native tests

Backends may reject unsafe or unsupported test config, but supported structured
config must fail closed with a clear error and receipt when the model cannot
produce valid governed output.

Visible example fixtures live in
`docs/bakeoff-contracts/fixtures/structured-output-visible.json`. They are
translation material for native tests, not the final evaluator.

## Required Schemas

Core native tests must cover `answer_v1`:

```json
{
  "type": "object",
  "required": ["answer", "confidence"],
  "properties": {
    "answer": {"type": "string", "minLength": 1},
    "confidence": {"type": "number", "minimum": 0, "maximum": 1},
    "citations": {"type": "array", "items": {"type": "string"}}
  },
  "additionalProperties": false
}
```

Advanced native tests should cover `answer_v2` as a schema alternative after
the core `answer_v1` path is complete:

```json
{
  "type": "object",
  "required": ["result", "confidence", "format_version"],
  "properties": {
    "result": {"type": "string", "minLength": 1},
    "confidence": {"type": "number", "minimum": 0, "maximum": 1},
    "format_version": {"type": "string", "enum": ["v2"]},
    "sources": {"type": "array", "items": {"type": "string"}}
  },
  "additionalProperties": false
}
```

The minimum semantic rule is `confidence >= 0.7` using `json_path_number` at
JSON pointer `/confidence`. Advanced schema-alternative tests use the same path
because both required schema families expose a top-level numeric `confidence`
field.

## Required Receipt Shape

Every governed request must write a receipt whose public fields include enough
information to reconstruct the path:

- selected synthetic model and provider target
- final structured-output status
- selected schema id for successful output
- parsed output for successful output
- attempt count
- ordered guard events
- guard event type, attempt index, rule id, guard type, and action
- exhausted rule id when a per-rule budget stops the loop

Expected final statuses:

- `completed`: first provider output passed all checks
- `completed_after_guard`: at least one guard event occurred before success
- `exhausted_guard_budget`: no valid output was produced before the configured
  attempt budget was exhausted
- `exhausted_rule_budget`: advanced status for a specific rule reaching
  `max_failures_per_rule` before the global attempt budget is exhausted. If
  `max_failures_per_rule` is `2`, the loop stops immediately after the second
  failure for that rule and does not consume a third provider output.

Expected guard types:

- `json_syntax`: output is not parseable as a single JSON value
- `schema_validation`: output parses as JSON but violates schema
- `semantic_validation`: output passes schema but fails semantic rules

Expected guard action:

- `retry_with_validation_feedback`

## Core Native Scenarios

Native test suites must translate the following behavior first, not merely copy
names. They may add additional cases.

| Scenario | Output path | Expected result |
|---|---|---|
| valid first output | valid JSON object with confidence above threshold | `completed`, zero guard events |
| semantic failure then success | schema-valid object has low confidence, then valid output | one `semantic_validation`, then `completed_after_guard` |
| syntax, schema, semantic, success | malformed JSON, missing required field, low confidence, then valid output | three guard events in order, then `completed_after_guard` |
| markdown fenced JSON then success | prose/fenced JSON output, then plain valid JSON | `json_syntax`, then `completed_after_guard` |
| refusal text then success | natural-language refusal, then valid JSON | `json_syntax`, then `completed_after_guard` |
| truncated JSON then success | incomplete JSON object, then valid JSON | `json_syntax`, then `completed_after_guard` |
| extra field then success | strict schema violation via additional field, then valid JSON | `schema_validation`, then `completed_after_guard` |
| wrong type then success | confidence emitted as string, then number | `schema_validation`, then `completed_after_guard` |
| repair overcorrects then success | syntax failure, then low-confidence JSON, then valid JSON | `json_syntax`, `semantic_validation`, then `completed_after_guard` |
| budget exhausted by syntax failures | repeated malformed outputs until `max_attempts` | fail closed with `exhausted_guard_budget` |
| budget exhausted by mixed failures | syntax, schema, and semantic failures without success | fail closed with `exhausted_guard_budget` |

For each scenario, native tests should assert status, attempt count, guard event
order, guard rule ids, selected schema, and whether parsed output is present.

## Advanced Native Scenarios

These scenarios are differentiators. They should be attempted only after all
core native scenarios pass.

| Scenario | Output path | Expected result |
|---|---|---|
| answer_v2 schema alternative succeeds | provider returns an object matching `answer_v2` rather than `answer_v1` | `completed`, selected schema is `answer_v2` |
| schema alternative repair succeeds | invalid `answer_v1`-shaped output, then valid `answer_v2` output | guard event followed by `completed_after_guard`, selected schema is `answer_v2` |
| no schema alternative matches | output shape is valid JSON but matches neither configured schema | `schema_validation` guard, then retry or fail closed |
| per-rule budget exhausted | the same rule reaches `max_failures_per_rule` while global attempts remain | fail closed immediately with `exhausted_rule_budget` and exhausted rule id |

## Property And Fuzz Expectations

Each backend should include native generated tests where practical:

- generated valid answer objects with non-empty `answer`, finite confidence in
  `[0.7, 1.0]`, and optional string citations should complete without guards
- generated invalid-first sequences should produce exactly one guard event
  before a generated valid answer succeeds
- generated all-invalid sequences of length `max_attempts` should fail closed
  with exactly `max_attempts` guard events
- generated confidence values below `0.7` should never complete successfully
  unless a later attempt repairs them
- generated additional object fields should be rejected when
  `additionalProperties` is false

Advanced generated tests, after core properties pass:

- generated repeated failures of the same rule should stop at
  `max_failures_per_rule` even when `max_attempts` is larger
- generated valid objects for every configured schema alternative should select
  the schema they match

Generated tests should avoid implementation details. Assertions should focus on
public responses, receipts, and guard-loop path shape.

## Live-LLM Discovery

Agents may run optional live-LLM discovery tests against local Ollama or an
authorized provider. Live tests are for realism only. They should not be used as
the final correctness gate.

When a live run reveals a useful failure, reduce it into a deterministic native
fixture that records:

- provider or local model name
- prompt family
- observed output shape
- violated invariant
- minimized canned output sequence

## Done Criteria

An implementation attempt is complete when:

- native tests cover the required scenarios and generated properties
- native mutation checks or equivalent deliberate breaks demonstrate tests can
  fail for the intended reason
- normal backend checks pass
- known limitations are recorded in `docs/bakeoff-results/<feature>-<backend>.json`
- the backend is ready for external held-out Python oracle evaluation
