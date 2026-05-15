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
- state-machine phases, states, transitions, and terminal outcomes
- output/finalization rules
- receipt and alert side effects

Rules should be labeled as `parallel-safe`, `ordered`, `ambiguous`, or
`conflicting`. Users should not need to infer whether two rules can run
together from raw YAML.

State-machine authoring should be a structured builder, not a raw process-code
editor. Users should be able to define named states, triggering events, guard
conditions, transition actions, retry budgets, and terminal outcomes. The UI can
then highlight unreachable states, missing terminal paths, conflicting actions,
and loops without explicit bounds. Advanced users may review the deterministic
artifact directly, but the visual graph and simulator should remain the normal
authoring surface.

## Simulation Model

Simulation should show examples and counterexamples with receipts. For TTSR
rules, the first simulator should expose chunking, holdback size, trigger
offset, release timeline, retry behavior, and whether violating bytes reached
the consumer.

Generated counterexamples should be pinnable as regression fixtures, so the UI
becomes a bridge from intent to durable tests.

For state machines, simulation should show the visited path through states and
transitions, the event that caused each transition, the guards that passed or
failed, emitted normalized actions, retry counts, terminal state, and the receipt
events that would explain the run.
