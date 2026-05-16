---
layout: default
title: MVP Realness Inventory
description: Prototype seams that should become minimally real before Wardwright can be treated as a remote MVP.
---

# MVP Realness Inventory

This inventory separates real behavior from prototype scaffolding. The goal is
not to remove every fixture before MVP; it is to identify which seams must stop
pretending before remote users or external agents depend on them.

The current bar is not production completeness. A real but simplistic
implementation is acceptable when it preserves a plausible long-term interface,
keeps ownership boundaries clear, and behaves honestly under unsupported input.
Unsupported features should either be ignored because they are explicitly
non-authoritative for the current path, logged for later review, or rejected with
a clear error that names the missing capability.

## Recently Fixed

- State-machine simulation paths no longer infer states from hard-coded trace
  event ids. Trace events now carry `state_id` when the simulation knows the
  state, and the state-machine projection falls back to node membership only
  when that evidence is absent.

## Minimally Real Now

- Provider streaming is not purely mocked. The runtime can stream from
  OpenAI-compatible SSE and Ollama NDJSON targets through `ProviderRuntime`,
  parse upstream chunks incrementally, apply stream policy before release, and
  cancel provider work when policy halts.
- Stream termination is handled for the current supported paths. Wardwright
  emits downstream `data: [DONE]` after normal completion and after terminal
  policy/provider events once an SSE response has started.
- OpenAI-compatible SSE and Ollama NDJSON terminal metadata is preserved in
  receipts at a minimal allowlisted level. Receipts now expose stream format,
  completion status/reason, and common token/timing fields when providers emit
  them.
- Policy retry loops are real for stream guards. A retry can inject a reminder,
  reroute when the retry prompt exceeds the current model context window, and
  record the attempt path in receipts.
- History-aware policy cache behavior is backed by runtime storage and tests,
  not only projection fixtures.
- The policy-authoring API has protected HTTP endpoints for tool discovery,
  projections, simulations, validation, and persisted authoring scenarios.
  Scenario writes are minimal but real records consumed by simulations instead
  of hard-coded UI-only state. The store is memory-backed by default and can be
  configured to persist records to a local JSON file.

## Still Prototype Or Fixture Backed

- Projection simulations prefer persisted scenario records when present, then
  fall back to explicit fixture examples. Persisted records can be imported from
  receipts, but do not yet replay receipt inputs or execute generated inputs.
- The state-machine model is still embedded in projection code. It should move
  toward artifact-declared states/transitions or a compiler pass that emits a
  state projection from policy primitives and sandbox regions.
- Assistant authoring is a deterministic boundary only. `validate_policy_artifact`
  now executes a conservative structural/capability validation pass, while
  `propose_rule_change` remains an advertised future draft-only tool.
- Tool discovery is HTTP-shaped, not MCP-shaped. A Hermes or bespoke MCP adapter
  can wrap the same functions, but no MCP server is implemented yet.
- The policy workbench is mostly static projection plus live runtime/cache
  events. It can consume persisted scenario records, but does not yet execute
  user-authored scenarios or show artifact diffs.
- Canned providers remain first-class in tests and local configs. That is useful
  for deterministic coverage, but remote MVP needs a clear way to distinguish
  demo targets from production targets in UI and API responses.

## Provider Streaming Gaps Before Remote MVP

- Real-provider smoke tests should run outside CI against at least local Ollama
  and one OpenAI-compatible provider. Current tests use local fake HTTP
  providers, which prove transport shape but not provider-specific drift.
- Upstream stream metadata is only minimally preserved. OpenAI `finish_reason`,
  usage chunks, refusal fields, and common Ollama terminal timing/count fields
  are allowlisted in receipts, but role, tool-call, logprob, and arbitrary
  provider-specific deltas are not preserved.
- Downstream SSE chunks only emit content deltas and Wardwright terminal events.
  They do not preserve upstream role, tool-call, logprob, or usage deltas.
- Provider timeout is enforced by `ProviderRuntime`, but lower-level HTTP stream
  collection still has a hard-coded `180000ms` fallback. The outer timeout is
  the active guard for configured targets; the inner timeout should still be
  parameterized or documented as a safety fallback.
- Cancellation relies on cancelling the provider task and `:httpc` request.
  This is tested for local tasks and fake providers, but should be smoke-tested
  against real long-running streams to verify upstream sockets close promptly.
- Negotiation is minimal. The OpenAI-compatible adapter assumes
  `/chat/completions`, bearer auth, and text/event-stream. It does not yet
  handle provider variants that require extra stream options, alternate base
  paths, or nonstandard terminal frames.

Interface expectation:

- Provider adapters should publish a capability record before remote use:
  supported endpoint shape, streaming format, auth scheme, terminal metadata
  support, cancellation confidence, and unsupported options.
- Unsupported provider features should be ignored only when they cannot affect
  policy correctness. If they could affect safety, routing, stream release, or
  receipt truth, the adapter should fail clearly.

## Policy And Simulation Gaps Before Remote MVP

- Scenario records have a first minimal store: user-written, assistant-generated,
  fixture, and live-replay scenarios can be represented with source and pinned
  status. The store supports optional JSON-file durability and receipt import,
  but still lacks retention policy and durable regression export.
- Simulation should execute against compiled policy logic and selected scenario
  inputs instead of only returning canned projection examples.
- Property/regression export should be wired from pinned scenarios so users can
  turn surprising behavior into reviewable tests.
- State-machine projection needs source spans and artifact references, not only
  node ids, so the UI can explain which config or DSL clause created each
  state/transition.
- Sandboxed policy regions need clear uncertainty semantics in projection and
  simulation: what can be statically explained, what must be scenario-covered,
  and what remains opaque.

Interface expectation:

- Projection fields should remain deterministic and backend-owned even when the
  implementation underneath is simplistic.
- Simulation should report whether it used fixture scenarios, persisted
  scenarios, live replay, or generated inputs. A fixture-backed simulation is
  acceptable if the source is explicit.
- State-machine projections should describe their source: artifact-declared,
  compiler-derived, trace-derived, or default one-state.

## Security And Remote Operation Gaps

- Policy-authoring endpoints reuse localhost/admin-token protection. Remote MVP
  should decide whether authoring APIs require token-only access, CSRF/origin
  constraints, or a separate capability token model.
- Provider credentials need a finalized encrypted storage story. Environment
  variables are acceptable for local development, but remote operation needs
  fnox or an equivalent secret store with audit-friendly configuration.
- Receipts and cache data can contain sensitive prompts or derived facts.
  Redaction rules for UI/API responses should be explicit before remote use.
- Multi-node visibility is plausible via PubSub, but clustering is not a
  tested product path yet. Remote MVP should state whether it supports
  single-node operation only, or visibility across clustered nodes.

## Suggested Next Slices

1. Normalize provider metadata capabilities beyond terminal fields and publish
   the supported metadata contract in provider capability records.
2. Add a live-provider smoke test profile that is skipped by default but can run
   against local Ollama and one configured OpenAI-compatible target.
3. Spike Hermes MCP over the protected authoring API without changing policy
   engine internals.
4. Add retention and regression-export paths for pinned scenario records.
