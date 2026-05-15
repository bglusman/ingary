---
layout: default
title: BEAM and LiveView Roadmap
description: Tentative architecture direction for Ingary's Elixir, Gleam, and LiveView implementation.
---

# BEAM and LiveView Roadmap

The current working assumption is that Ingary's primary implementation should
move toward a BEAM architecture:

- **Elixir** owns runtime plumbing: HTTP, LiveView, supervision, registries,
  GenServers, ETS ownership, sidecar/NIF boundaries, provider calls, telemetry,
  dynamic config, and operational dashboards.
- **Gleam** owns correctness-heavy pure logic: policy/config data types,
  action/result ADTs, route arbitration, guard-loop state machines, cache
  eviction decisions, receipt classification, and projection generation where
  exhaustiveness materially reduces bugs.
- **Phoenix LiveView** owns the first-party operator UI so policy authoring,
  simulation, receipts, and runtime state can be driven directly from the same
  supervised backend.

This is a tentative selection, not a declaration that the other prototypes are
useless. Go and Rust remain useful comparisons for deployment footprint,
embedding, and policy engine experiments. The key difference is that Elixir and
Gleam do not need to compete as whole backends: each pure function or runtime
boundary can be assigned to the language that fits it best.

## Boundary Rule

Default to Gleam when all of these are true:

- the logic is pure or nearly pure
- invalid states can be represented with typed variants instead of ad hoc maps
- exhaustive pattern matching would catch real product mistakes
- the Elixir/Gleam boundary can be expressed as a small stable input/output
  shape

Default to Elixir when any of these are true:

- the code owns a process, supervisor, registry, socket, endpoint, ETS table, or
  sidecar
- behavior is intentionally dynamic or operator-configured
- the code needs mature Phoenix/Plug/LiveView/Ecto/Telemetry APIs
- the code is mostly orchestration, IO, or lifecycle management

Runtime call overhead between Elixir and Gleam should not drive the decision.
Both compile to BEAM modules. The real costs are build/tooling complexity,
library maturity, data-shape translation, and duplicated logic across the
boundary.

## Runtime Shape

The target process hierarchy is:

1. application supervisor
2. model registry and dynamic supervisor
3. one model runtime subtree per synthetic model/version
4. session registry and dynamic supervisor under each model runtime
5. one session runtime per caller/session/run
6. narrow workers for provider calls, sidecars, dirty NIF calls, alert queues,
   stream windows, and policy evaluation

Required runtime tests:

- crash one session and prove sibling sessions continue
- crash or restart one model runtime and prove other models continue
- saturate or timeout a sidecar/alert queue and prove unrelated failure domains
  do not inherit backpressure
- run a dirty NIF policy evaluation and document scheduler isolation separately
  from killability
- emit receipts with model id/version, session id, policy version, attempt id,
  and failure domain

Sidecars remain attractive for hard killability, but they must be scored as
backpressure and scaling risks: queue depth, single-worker serialization,
protocol failures, cold starts, restart storms, pool sizing, and cross-session
or cross-model saturation.

## LiveView Direction

The existing TypeScript prototype was useful for shape discovery, but the next
operator UI should be built in LiveView unless a workflow proves it needs a
client-heavy canvas app.

Initial LiveView surfaces:

- synthetic model catalog and version switcher
- policy projection workbench
- simulation runner with trace overlay
- receipt explorer and diff view
- runtime dashboard for model/session trees, queue depth, restarts, and policy
  failures
- advanced policy editor with a deterministic artifact preview

The UI must render stable backend projections rather than engine-specific
implementation details. The policy artifact and compiled plan remain the
authority; projection and simulation are review aids.

## Library Shortlist

Use Phoenix and LiveView primitives first. LiveView provides server-rendered
interactive UI, async cancellation, hooks, and server-to-client events for the
small amount of client-side behavior needed by graph widgets.

Recommended library posture:

| Area | Candidate | Use |
|---|---|---|
| Base LiveView UI | SaladUI or Petal Components | Try one small page before adopting broadly. SaladUI is shadcn-inspired with accessible components and charts; Petal is mature HEEX/Tailwind with optional LiveView.JS/Alpine behavior. |
| Accessible component kit | Fluxon UI | Evaluate if its component set fits dashboards better than SaladUI/Petal. |
| Interactive policy graph | LiveFlow | Spike for node graphs. It is very young, so treat it as experimental and keep a fallback path. |
| Custom graph/canvas | LiveView hook plus Cytoscape, D3, Mermaid, or custom SVG | Use only for graph interactions LiveView components cannot express cleanly. Keep the graph data shape server-owned. |
| Operations dashboard | Phoenix LiveDashboard plus custom pages | Use for VM/process/telemetry inspiration and possibly embed internal metrics pages. |

Avoid committing to a large UI kit before the policy projection contract settles.
The first goal is a dense operational workbench, not a marketing dashboard.

## Near-Term Spikes

1. **Projection Contract Merge**
   Review and merge the policy projection FE/BE contract work. The contract
   should describe projection nodes, confidence, effects, conflicts, simulation
   traces, and receipt previews without assuming React or LiveView.

2. **LiveView Projection Workbench**
   Keep the current LiveView projection prototype focused on three modes:
   phase map, effect matrix, and trace overlay. Add server-side tests for route
   behavior and projection shape before adding a UI component library.

3. **Gleam Decision Core**
   Extract one non-trivial state machine into Gleam and call it from the live
   Elixir path. Good candidates are structured-output guard-loop arbitration,
   TTSR action arbitration, and deterministic cache eviction.

4. **Runtime Isolation Demo**
   Build model/session dynamic supervisors in the primary Elixir backend and
   expose a small LiveView or admin endpoint that shows child trees, restarts,
   queue depth, and failure-domain receipts.

5. **Dune vs Starlark Sandbox Spike**
   Dune should be evaluated separately from Gleam. Gleam is a typed core
   language; Dune is an Elixir sandbox candidate. Compare Dune with Starlark on
   sandbox strength, timeout/reduction limits, source review, visualization,
   ergonomics, and sidecar/NIF/backpressure tradeoffs.
