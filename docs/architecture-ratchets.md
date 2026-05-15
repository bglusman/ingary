---
layout: default
title: Architecture Ratchets
description: Guardrails for keeping Wardwright understandable as AI-assisted changes accumulate.
---

# Architecture Ratchets

Wardwright should keep the architecture decisions explicit enough that an agent
can follow them and a reviewer can reject shortcuts. These rules translate the
failure modes described in ["I'm going back to writing code by hand"](https://blog.k10s.dev/im-going-back-to-writing-code-by-hand/)
into Wardwright-specific constraints.

## Ownership Rules

- Do not add a god module that owns unrelated routing, policy, storage, UI, and
  runtime state.
- Keep HTTP parsing, policy evaluation, route planning, provider transport,
  receipt persistence, and LiveView projection in separately named modules.
- A new behavior boundary should usually add or extend the owning module for
  that boundary, not add another branch to an unrelated dispatcher.
- When a change crosses boundaries, document the contract between them before
  wiring the behavior through.

## Policy Engine Rules

- Built-in governors should compile to typed phase-specific decisions before
  request execution. Avoid ad hoc maps flowing deep into execution paths.
- Programmable policy engines are behind a shared ABI. Do not let Dune,
  Starlark, WASM, or another sandbox leak engine-specific shapes into receipts,
  projections, or route planning.
- Policy failures must be represented as typed outcomes: allow, transform,
  retry, route, alert, block, or exhausted. Avoid booleans whose meaning depends
  on call-site convention.
- Feedback-loop behavior must record rule id, phase, attempt count, retry
  decision, and terminal status in receipts.

## State And Concurrency Rules

- Session and model runtime processes own their own state. Other processes ask
  for snapshots or send typed events; they do not mutate that state directly.
- Background provider calls, alert sinks, and simulation workers publish typed
  results back to the owning process or PubSub topic.
- LiveView state is a projection of backend artifacts and events. It must not
  become the authoritative source of policy or session state.
- ETS is runtime acceleration. Durable product behavior belongs behind the
  storage contract and must survive an implementation swap.

## Data Representation Rules

- Keep structured data typed until the display or wire boundary. Do not use
  positional arrays for policy phases, route graph edges, receipt events, or
  projection nodes.
- In Elixir, avoid untyped maps outside boundaries we do not control: JSON
  request bodies, config files, provider payloads, persistence payloads, and
  external sandbox results. Validate and parse those maps into structs or typed
  Gleam values before core routing, policy, storage, receipt, or projection
  logic relies on them.
- If a map must stay a map, document why the shape is intentionally open and
  keep all access to that shape near the boundary adapter.
- If ordering matters, name the ordered concept explicitly: priority, phase,
  attempt sequence, stream offset, receipt event sequence.
- If optionality matters, model it in the type or schema rather than relying on
  missing map keys deep in the call stack.

## Scope Rules

- Every new capability should map to one of the current product loops:
  synthetic model routing, governance, receipts, simulation/projection, policy
  authoring, or runtime visibility.
- Treat "easy to add" as a warning, not a reason. If the feature adds another
  branch to a central dispatcher or shared state container, stop and re-check
  the ownership model.
- Prototype code may be ugly for one PR, but the cleanup path must be explicit
  before it becomes a dependency for the next slice.

## Review Questions

Every non-trivial review should ask:

- Did this change make the owning boundary clearer?
- Did it add a special case to a central dispatcher?
- Could a typed state or decision make an invalid state impossible?
- Does async work report results through an owner, or mutate shared state?
- Does the UI consume projections and evidence, or start owning product truth?
- Would an agent reading only `AGENTS.md`, this file, and the touched modules
  know where the next related change belongs?
