---
layout: default
title: Governance Authoring
description: AI-assisted, visual, simulation-first governance authoring for Wardwright.
---

# Governance Authoring

Governance authoring should feel like designing and proving behavior, not
hand-writing a policy language. The durable artifact still needs to be
deterministic and reviewable, but most operators should work through an
assistant, graph, simulator, and diff review.

## Product Loop

1. Describe the desired behavior in plain language.
2. Choose whether the assistant may use a local or external backing model.
3. Review the drafted rule artifact and compiled policy summary.
4. Inspect the phase graph, effect set, and arbitration status.
5. Run generated simulations and counterexamples.
6. Revise until the policy behavior matches intent.
7. Activate an immutable policy version.

## Assistant Role

The assistant may draft, explain, review, and revise governance artifacts. It
does not run in the request path and it cannot activate a policy on its own.
Compiled artifacts, validation diagnostics, and simulator output are the source
of truth.

Assistant output should always be paired with:

- model and provider provenance
- whether external model access was used
- prompt template version
- user approval state
- exact artifact diff

## Visual Model

The UI should show policy as a phase graph:

- request rules
- route rules
- stream detectors and arbiters
- output/finalization rules
- receipt and alert side effects

Rules should be labeled as `parallel-safe`, `ordered`, `ambiguous`, or
`conflicting`. Users should not need to infer whether two rules can run
together from raw YAML.

## Simulation Model

Simulation should show examples and counterexamples with receipts. For TTSR
rules, the first simulator should expose chunking, holdback size, trigger
offset, release timeline, retry behavior, and whether violating bytes reached
the consumer.

Generated counterexamples should be pinnable as regression fixtures, so the UI
becomes a bridge from intent to durable tests.
