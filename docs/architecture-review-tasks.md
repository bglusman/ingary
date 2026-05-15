---
layout: default
title: Architecture Review Task Ledger
description: Tracked follow-up tasks from the adversarial architecture review.
---

# Architecture Review Task Ledger

This ledger converts the adversarial architecture review into tracked work. Keep
it current as implementation lands; unresolved `P1` items should block any
deployment with real provider credentials.

## Active Tasks

| ID | Priority | Area | Status | Task |
|---|---:|---|---|---|
| ARCH-001 | P1 | Security | In progress | Remove or gate prototype mutation surfaces before real credentials are configured. `POST /__test/config` is now disabled unless `:allow_test_config` or `WARDWRIGHT_ALLOW_TEST_CONFIG=1` is set. `/admin/*`, receipt reads, and policy-cache APIs now require loopback access or an admin token. Public synthetic-model discovery now returns summaries instead of route graphs, prompt transforms, or governance internals. This is a homelab/single-operator guard, not a complete product auth model. Provider API credentials should be managed separately through fnox-backed secret lookup. Remaining work is to define deployment-topology-specific caller authorization: local-only, SSO/reverse-proxy integration, API-key authorization to use specific synthetic models, or a database-backed user/permission system if the product later needs one. |
| ARCH-002 | P1 | Route policy | In progress | Make route-policy overrides fail closed by default. Forced missing/too-small models now block rather than fallback; remaining work is an explicit `allow_fallback` policy option if we decide fallback is product-meaningful. |
| ARCH-003 | P1 | Policy engines | In progress | Normalize primitive, Dune, WASM, and hybrid policy outputs into one action shape. Hybrid now propagates nested actions; remaining work is a formal action/result schema and conflict-resolution metadata. |
| ARCH-004 | P1 | TTSR | Open | Replace mock stream chunks with real provider stream holdback, abort/regenerate orchestration, retry budgets, and receipts that distinguish released, rewritten, retried, and blocked bytes. |
| ARCH-005 | P2 | Policy architecture | In progress | Keep moving policy evaluation out of HTTP request handling. Request governance now lives in `Wardwright.Policy.Plan`, and stable pure decisions are beginning to move into Gleam wrappers; remaining work is compiled plans, phase-specific evaluators, and projection/trace emission from the same plan. |
| ARCH-006 | P2 | State/history | Open | Replace process-local history/cache semantics with a storage boundary that can preserve deterministic history behavior across restart and multi-instance deployment. Recent history threshold classification now has a Gleam core, but storage ownership is still process-local. |
| ARCH-007 | P2 | Alerting | Open | Turn alert delivery from an in-memory capacity queue into a supervised sink abstraction with delivery workers, retry/dead-letter semantics, and queue health visibility. Alert enqueue/backpressure classification now has a Gleam core, but delivery is still in-memory and unsupervised beyond the app process. |
| ARCH-008 | P2 | Projection UI | Open | Stop hardcoding projection/simulation examples; generate workbench projection data from deterministic policy artifacts, compiled plans, and receipts. |
| ARCH-009 | P2 | Provider runtime | Open | Move provider calls behind supervised workers or pools with timeouts, cancellation, telemetry, circuit breaking, and credential lookup isolation. |
| ARCH-010 | P2 | Test quality | In progress | Add behavior tests for fail-closed policy semantics and make property tests exercise implementation paths, not only oracle helpers. New coverage exists for forced-route failure, hybrid propagation, test-config gating, and the Gleam-backed structured/history/alert decision cores. |

## Follow-Up Review Gates

- Before enabling real provider credentials: close `ARCH-001`, or explicitly
  document that the server is localhost-only or fronted by a trusted auth/SSO
  boundary. Do not treat provider credential storage, model-use authorization,
  and admin/configuration access as the same security problem.
- Before evaluating TTSR product quality: close `ARCH-004` enough to test a real
  streamed provider path, not only mock chunks.
- Before building a large policy UI: close enough of `ARCH-003` and `ARCH-005`
  that the UI consumes a stable backend projection rather than engine-specific
  implementation details.
- Before multi-session or remote integration testing: close enough of
  `ARCH-006` and `ARCH-007` that policy behavior does not depend on accidental
  local process lifetime.
