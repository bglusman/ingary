---
layout: default
title: Ingary Feature Spikes
description: Research-backed feature directions for policy examples and tests.
---

# Feature Spikes

This page is a working backlog for self-directed Ingary experiments. The goal
is not to chase every gateway feature. The goal is to find constrained agentic
workflows where a synthetic model policy layer can measurably reduce failures,
cost, latency, or diagnosis time.

## Research Signals

Recent agent-observability writeups emphasize failures that ordinary request
logs do not explain well: tool misuse, context loss, goal drift, retry loops,
multi-agent cascading errors, and silent quality degradation. Latitude's March
2026 failure taxonomy is especially relevant because it maps each failure mode
to a detection strategy and argues for turning production traces into
regression tests.

LangGraph's human-in-the-loop docs draw a useful boundary: true human approval
requires interrupting execution, persisting graph state, and resuming with an
explicit decision. Ingary's MVP alerting is much smaller: record a receipt
event and notify an operator without pausing the request.

oh-my-pi's Time Traveling Streamed Rules are the closest public analogue to
Ingary's stream-policy idea: regex-triggered output stream rules that activate
only when the model starts producing relevant content, abort the stream, inject
a reminder, and retry once per session. Ingary can generalize that into
backend-neutral synthetic model policy with explicit receipt semantics and
bounded release latency.

## Experiment Matrix

| Spike | Why it might matter | MVP shape | Cost/risk | Success metric |
|---|---|---|---|---|
| Structured output repair | JSON/XML drift is common and easy to test. | Final-output validator with retry-or-block. | Medium latency from retries; parser/schema design. | Lower invalid-output rate against fixtures. |
| Streaming TTSR | Known bad patterns can be stopped before consumers see them. | Buffered horizon, literal/regex trigger, retry with reminder. | Hard streaming semantics; visible latency. | Violating bytes never released in buffered mode. |
| Tool-loop detector | Retry loops are expensive and diagnosable from session facts. | Session rolling counter keyed by tool/args/result hashes. | Needs agent/tool metadata standardization. | Fewer repeated equivalent calls in generated traces. |
| Async alert sinks | Makes policy value visible before full approval workflow exists. | Receipt event plus webhook/Telegram/Slack sink adapter. | Sink failure/backpressure semantics. | Policy trip reliably creates auditable delivery record. |
| Approval gate | Valuable for irreversible operations, but not just a notification. | Pending request state, approve/edit/reject, timeout. | Requires durable state and client UX contract. | Resumable approval tests pass without duplicate side effects. |
| Prompt variant receipts | Makes Ingary useful as a prompt experiment boundary. | Versioned preamble/postscript transforms recorded in receipts. | Can become Helicone-style product sprawl. | Operators can compare outcomes by transform version. |
| Budget/context governor | Route decisions are central to synthetic models. | Run/session counters and context-threshold route actions. | Budget facts need deterministic cache semantics. | Generated threshold tests produce stable route/degrade/alert choices. |
| Trace-to-regression importer | Converts production failures into examples and tests. | Receipt fixture import to BDD scenario generator. | Needs stable receipt schema and redaction. | A labeled incident becomes a failing test before fix. |

## First Example Library

The example policies should be intentionally boring before they are clever:

1. **Ambiguous success**: alert when an agent claims completion but required
   artifact metadata is absent.
2. **JSON contract**: retry once with validation feedback, then block if JSON
   is still invalid or missing required semantic fields.
3. **Deprecated API TTSR**: withhold streamed code long enough to catch
   `OldClient(`, retry with a reminder, and prove the bad bytes were not
   released.
4. **Repeated tool call**: count equivalent tool calls in a session and inject
   a reminder or alert after N repeats.
5. **Budget step-up**: record when a route crosses from cheap/local to
   expensive/managed and alert when a session crosses a configured spend window.

Each example needs:

- a model definition
- a BDD scenario
- a generated/property variant
- a receipt fixture
- a UI state that shows the trigger, action, latency, and release status

## What Not To Overbuild Yet

- Hosted marketplace policy monetization: keep manifest/provenance hooks, but
  do not let it drive MVP complexity.
- Full arbitrary receipt queries inside policy code: use deterministic declared
  working sets first.
- Synchronous human approval: document the contract now, implement after
  persistence/resume semantics are real.
- Provider-specific prompt management parity: record prompt transforms and
  variants first; broader A/B analytics can wait until receipts are richer.
