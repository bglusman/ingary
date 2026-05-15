---
title: Bakeoff Attempt 2 Results
description: Historical results from the second backend bakeoff attempt.
---

# Bakeoff Attempt 2 Results

Attempt 2 used branch `codex/run-all-structured-bakeoff-tests` commit `cd875e1`
as the shared base for all prototype worktrees. Agents received visible English
contracts; structured output also had a visible JSON fixture. Python evaluators
were hidden from their worktrees.

The external evaluator results below are the post-delivery Python tests run from
the shared workspace against each completed backend. For history and alerts, the
full Python files were run without marker filtering, so the total counts include
pure oracle/property tests. Backend score is called out separately because that
is the implementation-facing part of the result.

## Summary Matrix

| Feature | Prototype | Commits | Harness min | Input | Cached input | Output | Reasoning | Cache hit | Weighted uncached | External result |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Structured output | Go | `dd09371` | 6.08 | 2,113,405 | 1,964,160 | 14,964 | 2,099 | 92.94% | 224,065 | 6/9 backend |
| Structured output | Rust | `929ddf4`, `c4077c3` | 7.23 | 2,938,231 | 2,773,760 | 17,913 | 2,509 | 94.40% | 254,036 | 6/9 backend |
| Structured output | Elixir | `35b422a`, `84e272d` | 6.89 | 3,212,192 | 3,073,024 | 15,485 | 2,065 | 95.67% | 216,593 | 6/9 backend |
| History governor | Go | `97c8055`, `a66816b` | 6.90 | 2,769,805 | 2,675,328 | 18,639 | 3,854 | 96.59% | 187,672 | 8/10 total, 2/4 backend |
| History governor | Rust | `7bd14c5`, `6f03d0d` | 7.06 | 3,528,222 | 3,430,528 | 16,015 | 2,891 | 97.23% | 177,769 | 8/10 total, 2/4 backend |
| History governor | Elixir | `8f20bb7`, `6a9d1d7` | 7.58 | 2,274,856 | 2,172,928 | 16,605 | 3,456 | 95.52% | 184,953 | 8/10 total, 2/4 backend |
| Alert backpressure | Go | `2de5185`, `b384aeb` | 8.15 | 2,740,473 | 2,660,992 | 19,442 | 4,826 | 97.10% | 176,691 | 8/11 total, 0/3 backend |
| Alert backpressure | Rust | `20f395d`, `7e8e37c` | 7.89 | 2,651,603 | 2,551,424 | 18,914 | 3,549 | 96.22% | 194,749 | 8/11 total, 0/3 backend |
| Alert backpressure | Elixir | `3a317ff`, `5f6ccba` | 9.89 | 4,303,746 | 4,139,392 | 20,913 | 4,148 | 96.18% | 268,919 | 8/11 total, 0/3 backend |

`Weighted uncached` is uncached input plus five times output tokens. It excludes
cached input and treats output as 5x more expensive for rough cost comparison.

## External Evaluator Findings

Structured-output results were identical across prototypes: all passed the
success path and advanced schema cases, but failed terminal guard budget
semantics. The failures were:

- global guard budget exhaustion must fail closed with a reconstructable receipt;
- per-rule budget exhaustion must fail closed with the exhausted rule id;
- repeated semantic failures must stop at the per-rule budget.

History-governor results were also nearly identical. All three passed manual
event insertion, deterministic timestamp-then-sequence eviction, and concurrent
write visibility. They failed receipt shape and/or normal request ingestion:

- Go and Elixir counted correctly but omitted `scope.session_id` from policy
  action receipts.
- Rust returned `scope` as a string in one receipt, and did not make normal chat
  requests feed the session history policy.

Alert-backpressure results exposed a larger contract miss. The pure queue oracle
tests passed, but every backend-facing alert test failed for all prototypes:

- fast sink requests produced `alert_count = 0`;
- queue-full/dead-letter tests had no `alert_delivery` outcome evidence;
- fail-closed queue-full chat requests returned HTTP 200 instead of 429 or 503.

The common failure pattern suggests the visible contract did not force agents to
wire `request_guard` plus `alert_async` through both synthetic simulation and
normal chat completion paths with the exact evaluator config shape.

## Process Notes

The second round was better instrumented than the first round: the agents did not
see or run the Python evaluators, and the post-delivery evaluator run had no
`deselected` ambiguity. The alert result still shows that visible contracts and
fixtures need to be more concrete before the next round, or the scoring will
measure config-shape guesswork as much as implementation quality.

For a next attempt, the strongest improvement would be to include one small
visible request/receipt JSON example per backend-facing behavior, while keeping
the larger Python evaluator hidden. That should preserve held-out evaluation
without leaving room for incompatible but superficially plausible config shapes.
