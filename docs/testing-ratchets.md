---
layout: default
title: Testing Ratchets
description: Guardrails for keeping Wardwright tests behavior-focused and maintainable.
---

# Testing Ratchets

Wardwright should treat tests as part of the product architecture. A passing
suite is not enough if failures are hard to localize, fixtures hide the behavior
under review, or broad files become a dumping ground for unrelated changes.

## Organization Rules

- Do not add new tests to a generic `WardwrightTest` module.
- Name test files by behavior boundary: route policy, stream retry, provider
  transport, policy cache, storage/admin, LiveView projection, and similar.
- Keep shared router setup in `app/test_support/router_case.ex`. Do not
  duplicate request helpers or base synthetic model fixtures in individual test
  files.
- If a test file grows past roughly 500 lines, split it by user-visible behavior
  before adding more cases.
- Prefer a slightly longer file name over an ambiguous one. `route_policy_test`
  is better than `router_test` when the behavior under review is policy
  constraints on routing.

## Assertion Rules

- Assert behavior and receipts, not private implementation steps.
- A policy test should usually prove at least one externally meaningful field:
  HTTP status, selected model, released stream content, route constraints,
  receipt events, failure status, or alert state.
- A simulation test should distinguish authority from evidence. The compiled
  policy artifact is authoritative; simulation and projection output explain it.
- Property tests should describe the generated space and include negative cases
  that would fail for plausible bugs.
- Tests that exercise fail-closed behavior should prove the unsafe provider path
  was not invoked or unsafe bytes were not released when that matters.

## Review Ratchets

Every non-trivial commit should answer:

- What behavior would break if this test failed?
- Is the test capable of failing for the bug it claims to cover?
- Does the test assert a public contract rather than a private shape?
- Does the fixture encode the product rule plainly enough for review?
- Did this change make the architecture easier to inspect, or just add another
  special case?

These are intended to counter common AI-assisted coding failure modes: sprawling
files, plausible but shallow coverage, fixture drift, hidden implementation
coupling, and code that passes local tests while becoming harder to reason about.
