# Policy Projection Contract

Wardwright policy engines may use structured primitives, Starlark, WASM, hybrid
composition, or future pluggable runtimes. The UI must not depend on those
implementation details. It should depend on stable projections emitted by the
policy compiler or engine adapter.

## Authority Model

1. The normalized deterministic policy artifact is the source of truth.
2. The compiled execution plan validates and lowers that artifact for runtime.
3. The policy projection describes the compiled plan for review.
4. Simulation runs exercise the compiled plan against examples and
   counterexamples. They are evidence, not authority.
5. Receipts record what happened during live or simulated execution.

## Engine Descriptor

Each engine reports:

- `engine_id`
- `display_name`
- `language`: `structured`, `starlark`, `wasm`, `hybrid`, or `opaque`
- `version`
- capabilities:
  - supported phases
  - static analysis availability
  - scenario generation availability
  - trace explanation availability
  - source span availability

The descriptor is not permission to render arbitrary custom UI. It tells
Wardwright which review surfaces can be honest and which must show opacity.

## Plan Projection

`PolicyPlanProjection` is the stable review shape:

- artifact reference and hash
- engine descriptor
- phase projections
- plan nodes
- declared/inferred effects
- conflict findings
- opaque regions
- warnings

Nodes can represent structured rules, Starlark functions, WASM module
entrypoints, arbiters, or opaque regions. Each node reports:

- phase
- label and summary
- projection confidence: `exact`, `declared`, `inferred`, or `opaque`
- reads
- writes
- actions
- optional source span

The UI should make confidence visible. Opaque projections are acceptable, but
they must not be displayed as if Wardwright understands their internals.

## Simulation Run

`PolicySimulationRun` records one scenario against one artifact hash and engine:

- scenario id and title
- input summary
- expected behavior
- verdict: `passed`, `failed`, or `inconclusive`
- trace events
- receipt preview

Trace events should connect concrete behavior back to projection nodes where
possible. Missing node links are allowed for opaque engines, but should reduce
review confidence.

## Boundary

Policy engines may emit projection metadata and declarative render hints in the
future. They should not provide executable frontend components for the core
review path. Wardwright owns the visual grammar so review, activation, audit, and
diff workflows remain consistent across engines.
