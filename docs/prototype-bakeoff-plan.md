---
layout: default
title: Prototype Bakeoff Plan
description: Experiment plan for choosing Wardwright's primary backend prototype using comparable feature implementations.
---

# Prototype Bakeoff Plan

Wardwright currently keeps Go, Rust, Elixir, and a proposed Gleam-on-BEAM variant
alive so the first durable implementation can be chosen from evidence instead of
preference. The bakeoff
turns that intention into a controlled experiment: three non-trivial governance
features, implemented independently in each prototype, scored with a
rubric defined before implementation begins.

The goal is not to prove that one language is universally better. The goal is
to identify which prototype gives Wardwright the best combination of correctness,
authoring semantics, runtime behavior, testability, maintenance quality, and
delivery cost for the product we are actually building.

## Experiment Matrix

Each row is one bakeoff feature. The original matrix used Go, Rust, and Elixir
for nine implementation attempts total. Add Gleam as a fourth evaluated variant
for all three bakeoffs before selecting a primary prototype.

The Gleam variant should be evaluated as **Elixir runtime shell plus Gleam typed
business-logic core**, not as a replacement for Elixir's HTTP/application
boundary. Elixir remains responsible for application supervision, dynamic
process registries, provider/model/session lifecycle, and integration with
existing Plug/Cowboy surfaces. Gleam owns policy/config data types, pure
decision functions, validation, routing math, cache/event classification, and
other logic where static exhaustiveness and type safety should reduce policy
bugs.

| Bakeoff | Go | Rust | Elixir | Gleam-on-BEAM | Primary signal |
|---|---|---|---|---|---|
| Portable structured-output governor | `bakeoff/json-go` | `bakeoff/json-rust` | `bakeoff/json-elixir` | `bakeoff/json-gleam` | Policy semantics, provider normalization, receipt quality |
| Concurrent recent-history governor | `bakeoff/history-go` | `bakeoff/history-rust` | `bakeoff/history-elixir` | `bakeoff/history-gleam` | Correctness under load, cache contention, deterministic eviction |
| Async alert sink with backpressure | `bakeoff/alerts-go` | `bakeoff/alerts-rust` | `bakeoff/alerts-elixir` | `bakeoff/alerts-gleam` | Supervision, latency isolation, retries, queue behavior |

Gleam may score poorly in areas where ecosystem libraries are immature or where
Elixir has better operational ergonomics. That does not make the spike a
failure. The evaluation should separately score:

- whether typed business logic made invalid policy/config states harder to
  represent
- how much FFI/interop glue was required at the Elixir boundary
- whether tests became clearer or more robust because of typed ADTs
- whether compile-time friction slowed delivery more than it improved
  correctness
- whether dynamic BEAM supervision remains clear when the core logic moves to
  Gleam modules

TTSR is not a fair first bakeoff because Rust already has a working spike and
the starting line is not equivalent. It should remain a later stream-governance
follow-up after the bakeoff chooses or narrows the primary implementation.

## Feature Specs

### 1. Portable Structured-Output Governor

This is not just "validate JSON." Providers increasingly support structured
outputs, but they expose different schema subsets, strictness levels, streaming
constraints, refusal behavior, and cache/compile latency. Wardwright's
differentiator is provider-portable output governance.

Required behavior:

- configure multiple acceptable output shapes or schema versions
- select a provider path: native strict schema when available, JSON mode plus
  validation when available, or plain completion plus repair when necessary
- tolerate policy-declared nullable, optional, missing, or defaultable fields
- validate semantic business rules that provider JSON-schema modes cannot
  guarantee
- treat validation failure as a non-terminal guard event when policy permits
  repair, redaction, prompt refinement, or regeneration
- stop looping only when generation succeeds, a configured global attempt budget
  is exhausted, or a configured per-rule failure budget is exhausted
- record receipt events for selected schema, provider capability path,
  validation errors, guard events, repair attempts, retry count, and final
  status

The visible contract and held-out oracle should cover valid output, syntax-invalid output,
schema-invalid output, semantically-invalid output, schema alternative
selection, tolerated optional/missing fields, recovery after one or more guard
events, and exhausted-loop failure.

### 2. Concurrent Recent-History Governor

This extends the policy cache into a realistic runtime governor. It is designed
to expose cache architecture, concurrency, latency, and eviction differences.
The initial bakeoff should limit history queries to a single session/run scope.
Cross-session history search is deferred until the product model can specify
which caller, tenant, project, consent, and retention boundaries make such
queries safe and useful.

Required behavior:

- count matching request, response, tool-call, or receipt events over a bounded
  recent window within the current session/run scope
- support regex/literal match conditions over recent event fields
- trigger route switch, alert, or reminder injection when thresholds trip
- isolate session/run scopes so events from one scope never influence decisions
  in another scope
- evict deterministically by timestamp and sequence under concurrent writes in
  the same session/run scope
- preserve request-path p95/p99 latency under concurrent cache load
- expose receipt events explaining count, scope, threshold, action, and cache
  working set size

The visible contract and held-out oracle should cover scope isolation, regex match counts, equivalent
events arriving concurrently within one session, deterministic eviction,
threshold non-trigger, threshold trigger, irrelevant in-scope events that do not
match the rule, out-of-scope events that would match but must not count, and
latency/load probes.

### 3. Async Alert Sink With Backpressure

Alerting is a first-class governance action and a good way to test runtime
supervision and failure isolation. The request path should remain bounded even
when an alert sink is slow or failing.

Required behavior:

- enqueue policy alert events to a mock webhook/sink without blocking the
  request path beyond a configured budget
- retry failed sink deliveries with bounded attempts
- expose queue depth, dropped/dead-lettered alerts, retry counts, and delivery
  status in admin or receipt surfaces
- support graceful shutdown without losing accepted in-memory alerts in tests
- apply backpressure policy when the queue is full: drop, dead-letter, or fail
  closed according to config
- keep alert delivery side effects idempotent by alert id

The visible contract and held-out oracle should cover fast sink, slow sink, failing-then-recovering
sink, full queue behavior, duplicate alert idempotency, and request-latency
budget under sink pressure.

## Guard Loop Semantics

TTSR-style rejection is a guard event, not necessarily a terminal outcome. A
policy can stop current generation, preserve safe output, redact unsafe spans,
inject validation feedback, restart from a different point, switch model or
provider, or escalate to a terminal block. Tests should therefore avoid
asserting only "rejected" or "accepted" when the behavior under test is a
governed loop.

For governed-loop features, the shared contract should assert:

- number and type of guard events before final completion
- whether each guard event stopped streaming, redacted output, preserved partial
  output, refined the prompt, restarted generation, switched model, or blocked
- final outcome: successful completion, successful completion with redactions,
  terminal block, or exhausted attempt budget
- global attempt count and per-rule failure count
- deterministic behavior when multiple guards fire on the same generation step
- receipt ordering across model output, guard trigger, repair action,
  regeneration attempt, and final outcome
- bounded loops: no policy can retry forever, and exhausting the budget produces
  an explicit terminal receipt

Mocked-model tests should drive canned sequences such as invalid output followed
by valid repaired output, repeated invalid output until budget exhaustion,
partial streaming output that is stopped mid-span, and multiple rules firing on
one response. Canned scenarios should live in reviewable JSON fixtures so policy
authors can inspect and extend the behavior corpus without reading test code.
Live-LLM tests are useful during development for realism and input diversity,
but they should be marked explicitly, excluded from default CI, and treated as
exploratory unless their prompts, model, seed/config, and observed
counterexamples are captured as regression fixtures.

## Test-First Workflow

Every bakeoff starts with a reviewed visible contract and a separate held-out
evaluation oracle before implementation branches are created.

1. Write a visible contract pack under `docs/bakeoff-contracts/<feature>.md`.
   It should describe public API behavior, policy semantics, expected receipt
   shape, native-test translation requirements, and optional live-LLM discovery
   guidance. Agents may read this contract.
2. Add visible example fixtures only when they clarify the contract. These
   fixtures are translation material, not the final judge.
3. Write the final Python backend oracle separately from the agent worktree.
   It should hit only public/prototype test APIs and assert externally visible
   behavior. Agents must not run this oracle during implementation.
4. Confirm the held-out Python oracle fails against all three backends for the
   expected missing-feature reasons.
5. Hold a human review gate on both the visible contract and held-out oracle.
   The review should judge whether scenarios, data generation, edge cases, and
   failure messages are strong enough to guide the bakeoff and catch shallow
   implementations.
6. Create the three implementation branches from the same `main` commit, using
   worktrees that expose the visible contract but not the held-out oracle.
7. In each branch, translate the visible contract into native tests first:
   Go `testing`, Rust unit/property tests, Elixir ExUnit/StreamData. The native
   translation is part of the evaluated work product.
8. Implement until native tests pass. Agents are encouraged to add additional
   native tests when they observe vacuous passes, untested branches, or live
   counterexamples.
9. Agents may run optional `live_llm` discovery tests during development when
   credentials or local models are available, including local Ollama. They may
   adapt those live tests for the backend they are building. Live tests are
   discovery and realism tools, not CI gates and not the final oracle.
10. After each agent finishes, run the held-out Python backend oracle externally
   against the completed backend as the final correctness gate.
11. Run the normal repo checks and collect metrics.

Native tests are part of the scoring. A backend should not get full credit for
passing the held-out oracle if the native test translation is shallow or tests
implementation details instead of behavior.

Useful live failures should be reduced into deterministic native regression
fixtures before the implementation is considered complete.

Agents should also consider lightweight mutation testing before declaring a
feature done: deliberately break a condition, branch, guard action, eviction
rule, or receipt field and confirm the native tests fail for the intended
reason. Held-out Python oracle failures are measured externally after the agent
finishes.

## Contract And Oracle Quality Bar

The visible contract and held-out Python oracle are not smoke tests. Together
they define and evaluate bakeoff behavior and should be reviewed before kickoff.
A weak contract or oracle will produce misleading implementation scores.

Each bakeoff test suite should include:

- hand-written BDD scenarios for the main user-visible workflows
- generated/property cases for state spaces where example tests are too narrow
- negative cases that prove the feature can fail for the right reason
- malformed, partial, duplicate, out-of-order, and boundary inputs where the
  feature accepts event streams or provider outputs
- adversarial cases drawn from real provider behavior where possible, such as
  refusals, truncation, markdown-wrapped JSON, schema drift, delayed sinks,
  duplicate delivery, and concurrent event races
- minimal counterexample output that can be pinned as a regression fixture
- assertions on receipts and traces, not just HTTP status and final content
- assertions on guard-loop path shape where relevant: guard count, guard type,
  repair action, attempt budget, and eventual success or terminal stop
- explicit checks that unsupported or unsafe configurations fail closed
- stable seeds and optional seed override for reproduction
- clear failure messages that identify the policy, scenario, generated input,
  and expected invariant
- a clear split between deterministic mocked-model tests and optional live-LLM
  realism tests that do not run in default CI

Before writing each visible contract and held-out oracle, inspect relevant
real-world open source test suites and provider examples for style and edge
cases. Useful sources include
JSON Schema test suites for structured-output behavior, webhook/retry queue
tests for alert sinks, and cache/concurrency tests from production-grade
libraries. Borrow test ideas and data shapes, not project-specific code, unless
the license and attribution path are explicitly acceptable.

The kickoff checklist for each bakeoff contract and oracle:

| Gate | Requirement |
|---|---|
| Scenario coverage | At least one success, one retry/recovery, one hard failure, and one configuration rejection. |
| Generated coverage | Property/generative tests cover meaningful ranges rather than a few constants. |
| Cross-backend neutrality | Tests assert the public contract and receipts, not backend internals. |
| Reviewability | The user can read the fixtures and understand what behavior is being required. |
| Failure evidence | A failing case prints enough input, receipt, and policy context to diagnose the issue. |
| Rigor review | The suite is reviewed and accepted before any implementation branch starts. |

## Controls

- All implementation branches start from the same `main` SHA.
- The visible feature contract and held-out Python oracle are frozen before
  implementation starts.
- Each implementation receives the same prompt, acceptance criteria, and
  validation commands.
- Implementation worktrees expose the visible contract but not the held-out
  Python oracle.
- Do not cross-port code or design details until all three attempts for that
  feature are complete.
- Dependency additions are allowed, but each addition is scored for maintenance
  and runtime cost.
- All commits get the standard adversarial code review before publication.
- The visible contract, native tests, held-out oracle result, and PR description
  must identify known limitations explicitly.

## Metrics To Capture

Each implementation attempt writes a small result artifact:
`docs/bakeoff-results/<feature>-<backend>.json`.

Suggested fields:

```json
{
  "feature": "portable_structured_output_governor",
  "backend": "rust",
  "branch": "bakeoff/json-rust",
  "base_sha": "example",
  "start_time": "2026-05-14T00:00:00Z",
  "first_native_tests_passing_time": "2026-05-14T00:00:00Z",
  "held_out_oracle_passing_time": "2026-05-14T00:00:00Z",
  "review_ready_time": "2026-05-14T00:00:00Z",
  "input_tokens": null,
  "output_tokens": null,
  "cached_input_tokens": null,
  "uncached_input_tokens": null,
  "cache_hit_rate": null,
  "reasoning_output_tokens": null,
  "weighted_total_input_plus_5x_output": null,
  "weighted_uncached_input_plus_5x_output": null,
  "tool_calls": null,
  "files_changed": 0,
  "lines_added": 0,
  "lines_deleted": 0,
  "dependencies_added": [],
  "checks": {
    "native": "pass",
    "held_out_python_oracle": "pass",
    "mise_check": "pass",
    "gitleaks": "pass"
  },
  "known_limitations": []
}
```

Token usage is useful when available. Capture total input, cached input,
uncached input, output, and reasoning output separately. Output tokens are
weighted more heavily than input tokens in the initial cost proxy. Cached input
tokens should not be hidden inside total input because cache hit rate may make
otherwise-expensive runs materially cheaper and may reward stable prompts,
shared context, and repeated test harness setup.

If exact usage is not available, use wall-clock time, tool calls, review
iterations, dependency churn, and diff size as cost proxies.

Before real bakeoff branches start, run a tiny instrumentation probe to calibrate
what the harness can actually capture. The probe should use deterministic static
actions with known expected counts rather than an implementation task. Its job
is to test the measurement system itself: wall-clock timing, command counts,
input/output token estimates, weighted token cost, git diff effects, command
output size, and expected-versus-observed comparisons.

Initial local probe:

```sh
python3 scripts/bakeoff_harness.py \
  tests/fixtures/bakeoff_instrumentation/toy_static_actions.json \
  --output /tmp/wardwright-bakeoff-instrumentation.json \
  --artifact-dir /tmp/wardwright-bakeoff-instrumentation-artifacts
```

This harness intentionally supports approximate token counting without a
provider. When real agent runs are used, prefer direct provider or tool usage
metadata. If an external runner such as opencode is used, capture its session
export or stats output alongside the harness result. The initial cost proxy
reports both `total_input + 5 * output` and `uncached_input + 5 * output` until
provider-specific cached-input pricing is known.

The first probe is expected to be boring: it should run a few static commands,
produce no repository state change, and match expected action counts. Real
bakeoff runs should usually produce at least one new commit, so the harness
tracks final `HEAD`, commits added, and diff stats from base to final in
addition to dirty worktree status. If those expectations do not match, fix the
harness before launching real bakeoff agents.

Use `--artifact-dir` for calibration and real bakeoff runs so full command
outputs and the exact input blob are available for later tokenization and audit.
The JSON summary keeps previews and paths; the artifact directory preserves the
raw material.

Real-model Codex probe:

```sh
python3 scripts/bakeoff_harness.py \
  tests/fixtures/bakeoff_instrumentation/codex_real_model_no_tool.json \
  --output /tmp/wardwright-codex-real-model-probe.json \
  --artifact-dir /tmp/wardwright-codex-real-model-artifacts \
  --timeout 120
```

`codex exec --json` emits `turn.completed.usage`; the harness parses those
events into `model_usage` and derives cached/uncached input, cache hit rate,
output, reasoning output, and weighted token proxies. That is the preferred
accounting path for bakeoff runs when Codex is the agent runner.

A successful GPT-5.5 medium no-tool probe on 2026-05-14 captured:

- `input_tokens`: 22,332
- `cached_input_tokens`: 6,528
- `uncached_input_tokens`: 15,804
- `cache_hit_rate`: 29.2%
- `output_tokens`: 35
- `weighted_total_input_plus_5x_output`: 22,507
- `weighted_uncached_input_plus_5x_output`: 15,979

Initial calibration results:

- static local probes can reliably capture wall time, command count, command
  duration, command output size, git status before/after, untracked-file count,
  and expected-versus-observed comparisons
- local token counts are estimates unless the runner exposes provider usage;
  the fallback tokenizer is acceptable for relative calibration but not billing
  truth
- command output can dominate the output-token proxy, so harness plans should
  avoid noisy commands unless output volume is intentionally part of the
  measurement
- an isolated temp-git mutation probe verified that the harness can detect
  repository state changes when commands actually modify tracked files
- subagent self-reporting should be treated as supplemental evidence; prefer
  runner-level logs, provider usage metadata, or exported sessions when
  available
- a toy Codex subagent could report command count and whether it edited files,
  but could not self-report reliable wall-clock timestamps, stdout/stderr byte
  counts, or provider cost; this makes external harness instrumentation
  mandatory for bakeoff comparisons
- agent bakeoff runs should preferably use the same model family as this
  planning work, such as GPT-5.5 at medium or high reasoning effort, so runner
  differences do not swamp backend differences
- opencode is available locally and exposes `opencode run --format json`,
  `opencode export`, and `opencode stats`, but an initial no-tool probe used
  opencode's default provider path and failed with missing opencode API
  credentials; do not treat that mode as representative
- opencode is only interesting for bakeoff execution if it can be configured to
  call the same GPT-5.5/OpenAI-compatible model path or a Wardwright proxy that
  itself forwards to that model while preserving per-run telemetry

## Scoring Rubric

Score each implementation out of 100 after the post-commit adversarial review.

| Dimension | Points | What good looks like |
|---|---:|---|
| Held-out correctness | 20 | Passes all held-out Python backend scenarios and properties without backend-specific exceptions. |
| Native test translation | 15 | Native tests express the same behavior and can fail for real regressions. |
| Feature completeness | 15 | Implements the full frozen spec, including edge cases and receipt fields. |
| Code hygiene and maintainability | 15 | Clear structure, small interfaces, low special-casing, idiomatic backend style. |
| Runtime behavior | 10 | Good latency, bounded resource use, clean shutdown/backpressure behavior where relevant. |
| Observability and receipts | 10 | Explains decisions, actions, retries, failures, and policy state clearly. |
| Security and safety | 10 | No secret leakage, fail-closed where appropriate, bounded untrusted inputs. |
| Delivery cost | 5 | Low wall-clock time, low cached-adjusted token/tool use, low dependency churn, few review fixes. |

Tie-breakers:

- A severe security or correctness issue caps the score at 60 until fixed.
- Shallow tests cap the score at 75 even if the feature appears to work.
- Hidden provider-specific behavior that breaks portability caps the score at
  80 for portable-governance features.

## Decision Gates

After each bakeoff:

- If one backend wins by 10 or more points and has no blockers, mark it the
  feature winner.
- If scores are within 5 points, treat the bakeoff as inconclusive and record
  the differentiators instead of forcing a winner.
- If a backend fails the held-out Python oracle or has unresolved security blockers,
  it cannot win that bakeoff.

After all three bakeoffs:

- If the same backend wins at least two bakeoffs, make it the primary prototype
  for the next implementation phase.
- If Gleam materially improves correctness or policy semantics while Elixir
  remains strongest operationally, prefer a hybrid Elixir/Gleam architecture
  over treating them as mutually exclusive prototypes.
- If different backends win different bakeoffs, compare the winning categories
  to the product roadmap. Correctness and policy-authoring semantics should
  outrank raw throughput.
- If Elixir wins load/backpressure but not policy semantics, consider keeping it
  as a supervised sidecar or alert/cache runtime candidate while another
  backend owns core policy semantics.
- If no backend clearly wins, run one final tie-breaker: code-first Starlark AST
  and trace visualization in the two strongest backends.

## Execution Sequence

Do not launch all nine implementation jobs until the measurement process has
proved itself on real work.

1. Freeze the visible contract, held-out Python oracle, and base `main` SHA.
2. Launch the first wave as four concurrent jobs for one bakeoff feature, one
   per backend/variant.
3. Review the outputs, metrics, native test translations, held-out oracle
   failures/passes, and post-commit adversarial reviews.
4. If the data is comparable and the instructions produced useful work, launch
   the remaining jobs.
5. If the first wave exposes bad scoring, weak tests, unclear instructions, or
   untrustworthy instrumentation, revise the harness and rerun a smaller wave
   before spending the full bakeoff budget.

## Baseline Parity Audit Template

Before the first bakeoff, fill this table from live code:

| Capability | Go | Rust | Elixir | Gleam-on-BEAM | Notes |
|---|---|---|---|---|---|
| OpenAI-compatible chat endpoint |  |  |  |  |  |
| Synthetic simulate endpoint |  |  |  |  |  |
| Config mutation endpoint |  |  |  |  |  |
| Provider target config |  |  |  |  |  |
| Env/fnox credential references |  |  |  |  |  |
| Policy cache endpoints |  |  |  |  |  |
| `history_threshold` request policy |  |  |  |  |  |
| Stream governance/TTSR |  |  |  |  |  |
| Native property tests |  |  |  |  |  |
| Shared Python probes |  |  |  |  |  |
| Load-test harness |  |  |  |  |  |

## BEAM Runtime Isolation Requirement

The Elixir and Gleam-on-BEAM variants should explicitly model Wardwright runtime
isolation. The target process hierarchy is:

- application supervisor
- dynamic supervisor and registry for synthetic model runtimes
- one model runtime process or subtree per synthetic model/version
- dynamic supervisor and registry under each model runtime for active sessions
- one session process or subtree per caller/session/run
- provider/NIF/sidecar workers linked under the narrowest runtime that owns
  their failure domain

Required isolation behavior:

- a session crash terminates or restarts only that session subtree
- a model runtime crash terminates or restarts only that model subtree and its
  sessions
- one session's cache, retry loop, stream window, or Starlark/NIF failure cannot
  corrupt or crash other sessions
- Starlark through Rustler must use dirty schedulers for scheduler isolation,
  and the bakeoff should explicitly compare that with a killable sidecar/process
  boundary for hard timeout/fault containment. If a dirty NIF wedges, evaluation
  should show what is and is not contained by the model or session subtree.
- Sidecars must also be evaluated as possible backpressure and failure points:
  single-worker serialization, queue growth, protocol failures, restart storms,
  cold-start/build latency, per-model/session pooling strategy, and whether a
  saturated or crashing sidecar for one runtime can slow or fail other runtimes.
- receipts must identify model id/version, session id, policy version, retry
  attempt, and failure domain so postmortems can prove isolation worked

The bakeoff score should reward implementations that test this with observable
behavior: deliberately crash a session worker, timeout a policy/NIF/sidecar call,
and confirm another session under the same model plus another model runtime
continues to answer.
