---
title: Backend Selection Decision
description: Decision record for removing the Go and Rust backend prototypes and focusing Wardwright on the BEAM.
---

# Backend Selection Decision

Wardwright initially kept Go, Rust, and Elixir backend prototypes in the live tree
to compare implementation cost, correctness, testability, and runtime fit
against the same contracts. That comparison has now served its purpose. The live
implementation should focus on **Elixir plus Gleam on the BEAM**.

The project was called Ingary during the bakeoff. Wardwright is the tentative
product name going forward. Repository, API namespace, and Elixir module names
now use Wardwright; GitHub Pages is configured for `wardwright.dev`.

## Decision

- Move the active Elixir/LiveView application to `app`.
- Remove the old Go and Rust backend prototype directories from the live tree.
- Keep shared HTTP/storage/policy contracts and Python probes.
- Keep historical bakeoff docs and git history as the record of comparison.
- Update local hooks and mise tasks so routine checks exercise the active stack
  instead of maintaining removed prototypes.

## Why

The product direction increasingly depends on properties where the BEAM is a
natural fit:

- per-model and per-session supervision boundaries
- stream governors that can hold, inspect, rewrite, retry, or fail closed
- runtime receipts and policy traces tied to process-owned state
- LiveView policy visualization, simulation, and AI-assisted authoring
- Dune or other BEAM-native snippets for trusted local programmable policy
- Gleam for pure, typed policy state machines and projection generation

Go and Rust remain viable technologies for specific future boundaries, such as
sidecars, WASM tooling, native policy engines, or edge packaging. They no longer
need to be maintained as whole parallel backend prototypes.

## Policy Engine Implication

Policy execution should be split by trust tier:

- **Local trusted policy**: structured primitives and Dune-backed BEAM snippets,
  supervised with timeout, reduction, memory, and receipt controls.
- **Portable untrusted policy**: WASM, a sidecar, or a hosted policy service
  behind an explicit capability-based host ABI and provenance metadata.

This avoids overselling Dune as a hostile-code security boundary while still
letting Wardwright use BEAM-native ergonomics for local policy iteration.

## Reversal Criteria

Reintroduce a non-BEAM backend only if a concrete spike shows that BEAM cannot
meet a required product constraint, such as:

- unacceptable stream latency or scheduler impact under realistic load
- inability to isolate model/session/policy failures cleanly
- deployment footprint or packaging requirements that Elixir releases cannot
  reasonably meet
- a required policy engine or provider boundary that is materially simpler and
  safer outside the BEAM

Until then, backend work should start from the Elixir/Gleam architecture.
