---
layout: default
title: Policy Workbench Implementation Plan
description: Near-term implementation slices for Wardwright policy visualization, simulation, and AI-assisted authoring.
---

# Policy Workbench Implementation Plan

Wardwright's policy workbench should make complex governance behavior inspectable
before activation and explainable after live or simulated calls. The durable
artifact remains authoritative; the workbench renders projections, traces,
assistant proposals, and receipt evidence around that artifact.

This plan turns the current vision into small implementation slices that can be
reviewed independently.

## Product Spine

The first useful workbench loop is:

1. Select a synthetic model and policy artifact.
2. See the baseline route graph.
3. See policy overlays by phase and effect.
4. Run or load a simulation scenario.
5. Watch the trace path through route, policy, stream, and output phases.
6. Ask the assistant to explain or revise behavior.
7. Review an artifact diff and generated regression scenarios before activation.

Every UI element should answer one of three questions:

- What is configured?
- What would happen for this scenario?
- What evidence proves that behavior?

## Slice 1: Projection Contract Hardening

Goal: make the backend projection stable enough that UI experiments do not bind
to engine internals.

Deliverables:

- `PolicyProjection` emits typed node classes for route, policy, stream,
  output, alert, assistant, and external-sandbox nodes.
- Every edge has a reason, phase, and ordering/parallelism hint.
- Projection output identifies opaque programmable regions separately from
  built-in deterministic primitives.
- LiveView tests assert visible labels, phase grouping, and selected mode
  behavior.

Gate:

- A route+policy projection can show a request rule, route override, stream
  retry, output guard, alert, and receipt evidence without reading raw config
  maps in the template.

## Slice 2: Trace Overlay

Goal: show the path a simulated or live request took through the projection.

Deliverables:

- Trace event contract with `node_id`, `edge_id`, `phase`, `status`,
  `attempt_index`, and receipt/event references.
- LiveView mode that overlays visited, skipped, blocked, retried, and escalated
  nodes.
- Stream-specific trace details for holdback, trigger offsets, release timeline,
  retry/reroute, and whether violating bytes reached the consumer.

Gate:

- A TTSR retry scenario visually distinguishes unreleased failed attempt,
  rerouted retry, released final stream, and the receipt fields that support
  each claim.

## Slice 3: Scenario And Simulation Panel

Goal: make simulation a normal authoring tool, not a test-only backend detail.

Deliverables:

- Scenario records with request facts, expected behavior, source
  (`user_written`, `assistant_generated`, `fixture`, `live_replay`), and
  pinned-regression flag.
- Simulation result cards with expected vs actual status, visited phases,
  policy actions, route decisions, and receipt preview.
- Generated counterexamples can be saved as fixture candidates without becoming
  active tests automatically.

Gate:

- A user can run at least three canned scenarios against one policy and compare
  why each landed on allow, retry, or block.

## Slice 4: Assistant Tool Boundary

Goal: wire a bounded AI policy assistant without making it an invisible policy
engine.

Deliverables:

- Protected HTTP tool endpoints for external agents and future MCP adapters:
  `explain_projection`, `simulate_policy`, `propose_rule_change`, and
  `validate_policy_artifact`.
- Tool schemas for `explain_projection`, `simulate_policy`,
  `propose_rule_change`, `inspect_receipt`, `inspect_route_plan`, and
  `validate_policy_artifact`.
- Assistant responses must include artifact references, projection node
  references, or receipt references when making behavior claims.
- Proposed changes are shown as deterministic artifact diffs, never applied
  directly.
- Model/provider provenance and prompt template version are stored with every
  assistant draft.

Gate:

- The assistant can explain an existing rule and propose a small deterministic
  rule change, but activation still requires explicit operator approval.

## Slice 5: Authoring Diff And Regression Export

Goal: close the loop from conversation to durable behavior.

Deliverables:

- Artifact diff viewer with changed rule ids, phases, actions, ordering hints,
  conflict keys, and simulation deltas.
- Regression export path that turns pinned scenarios into reviewable test
  fixtures.
- Activation checklist that shows validation, simulation, unresolved opaque
  regions, and agent-escalation uncertainty.

Gate:

- A policy revision cannot be marked ready unless artifact validation passes and
  simulation results are attached or explicitly waived.

## UI Layout Direction

First screen should be the workbench, not a landing page:

- left rail: synthetic model, policy version, projection mode, scenario set
- center: route/policy graph with phase tabs and trace overlay
- right rail: assistant chat, artifact diff, and selected-node inspector
- bottom drawer: simulation timeline and receipt evidence

Keep panels dense and operational. Avoid decorative dashboards until the live
operator workflow is clear.

## Implementation Bias

- Prefer native LiveView plus SVG/HEEx for the first graph. Add Cytoscape only
  if pan/zoom/layout becomes a concrete blocker.
- Keep authoritative state server-side. Client hooks may render graph layout,
  but they should not own policy truth.
- Parse raw maps at boundaries into structs or typed Gleam values before core
  projection and simulation logic.
- Use PubSub for live receipt/runtime updates so the workbench naturally works
  in multi-node visibility mode.

## Open Questions

These should be answered through spikes, not long debate:

- Should MCP be served through an existing Elixir library such as Hermes, or is
  a small adapter over the protected authoring API enough for the first external
  agent workflows?
- Does native LiveView remain usable once route+policy graphs exceed roughly
  40 nodes?
- Should assistant scenarios become Python/StreamData-style shared oracle
  fixtures, native ExUnit fixtures, or both?
- How much of assistant tool orchestration should use Alloy first versus a
  minimal bespoke tool dispatcher?
- Which policy shapes should force a different visualization mode:
  declarative primitives, Dune snippets, WASM modules, or external hosted
  policies?
- What should the UI show when an agent-escalation path is invoked but its
  internal reasoning is unavailable or nondeterministic?

## Next Concrete Branches

1. `projection-contract-types`: introduce typed projection structs and keep the
   current LiveView output unchanged.
2. `trace-overlay-mvp`: add trace overlay state for existing simulation and
   stream retry receipt examples.
3. `scenario-panel-mvp`: add scenario selection and result cards backed by
   canned examples.
4. `assistant-tool-contract`: define tool schemas and a local no-model assistant
   stub that returns deterministic explanations.
5. `graph-render-spike`: compare native SVG against a Cytoscape hook on the same
   projection payload.
