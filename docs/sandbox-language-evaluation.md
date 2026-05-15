---
title: Sandbox Language Evaluation
description: Evaluation plan and early findings for Dune, Starlark, and other policy execution languages.
---

# Sandbox Language Evaluation

Wardwright should evaluate policy languages along two separate axes:

1. **Authoring quality**: whether AI and technical policy authors can produce,
   repair, explain, and review correct policies.
2. **Execution boundary**: whether the runtime can enforce bounded execution,
   fault isolation, deterministic outputs, and fail-closed receipts.

The primary user interface should remain natural-language assisted authoring,
projection visualization, simulation, and review. The language is an
implementation and storage detail unless a technical user opens the advanced
editor.

## Candidates

| Candidate | Primary value | Main concern |
| --- | --- | --- |
| Structured YAML/TOML policy | Best projection, validation, and UI explainability | May need many primitives before it covers advanced cases |
| Dune / Elixir subset | Native BEAM execution, allowlist, timeout, reduction, memory limits | Best-effort sandbox only; not a hostile multi-tenant boundary |
| Starlark sidecar | Portable deterministic policy language with mature Go/Rust engines | Sidecar lifecycle, backpressure, projection fidelity |
| Starlark Rustler NIF | Fast in-process Starlark semantics | NIF crash/scheduler risk even with dirty schedulers |
| JS/Deno | Strong model familiarity and mature tooling | Operational/runtime boundary is separate from BEAM supervision |
| Lua/Luerl | Designed for embedded scripting and BEAM-compatible options exist | Less likely to be authored well by generic LLMs than JS/Starlark/Elixir |

## Execution Tiers

Wardwright should not force one sandbox language to satisfy every trust model.
Policy execution should be split by provenance:

| Tier | Engines | Intended use | Boundary |
| --- | --- | --- | --- |
| Local trusted | structured primitives, Dune | operator-owned rules, AI-authored local snippets, fast iteration | BEAM supervision plus allowlist, timeout, reduction, memory, and receipt controls |
| Portable untrusted | WASM, sidecar, hosted policy service | externally shared packages, marketplace policies, third-party policy code | capability-based host ABI, fuel, memory limits, deterministic IO, provenance metadata |

Dune is therefore an ergonomics and local-control candidate. It should not be
marketed as the hostile-code boundary. WASM or an isolated external process
should be required before policy crosses an external trust boundary.

## Dune Spike Findings

The initial Elixir spike adds `Wardwright.PolicySandbox.Dune`, a thin adapter
that normalizes Dune success and failure structs into policy-engine result maps.
This is intentionally small so callers can fail closed without binding the rest
of Wardwright to Dune's API.

Executable tests currently verify:

- deterministic policy-shaped map results can be returned
- parsed code exposes a reviewable AST string while runtime atoms are rewritten
- file, environment, process spawn, and message-send attempts fail closed
- CPU-heavy policy work can be stopped by `max_reductions`
- large allocations can be stopped by `max_heap_size`
- low wall-clock budgets stop slow allowed work by timeout or reductions

One useful observation: recursive module-style code hit the memory cap before
the reduction cap in an early test. This is acceptable fail-closed behavior, but
it means Wardwright should treat timeout, reductions, and memory as complementary
controls rather than assuming one budget is authoritative.

## Evaluation Matrix

Each candidate should be scored on:

- correctness on the same TTSR, route privacy, cache/count threshold, model
  switch, and ambiguous-success policies
- AI authoring quality: first-pass correctness, repairability after validation
  errors, policy size, and explanation quality
- projection quality: static node/effect extraction, source spans, opaque-region
  reporting, and trace-to-node linkage
- bounded execution: timeout, fuel/reduction cap, memory cap, kill behavior,
  scheduler impact, and receipt visibility
- fault isolation: whether one model/session/policy failure can crash, block, or
  starve unrelated sessions
- security posture: host API access, filesystem/env/network denial, atom leaks,
  process/message access, imports/metaprogramming, and dependency trust
- operational cost: runtime dependencies, deploy shape, observability,
  backpressure, and upgrade/migration surface

## Near-Term Decision Gate

Dune should advance only if it remains strong on all of these:

- common policies are easier for AI to author and repair than Starlark
- projection from Dune AST plus runtime traces is honest enough for review
- timeout, reduction, and memory failures are typed and receipt-friendly
- default allowlist blocks host escape attempts relevant to Wardwright
- BEAM model/session supervisors stay responsive under hostile policy workloads

Even if Dune passes, it should initially be treated as a local/trusted advanced
policy engine. Hostile third-party policy still needs a stronger boundary such
as a sidecar, WASM runtime, microVM, or hosted policy service.
