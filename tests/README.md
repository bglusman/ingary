# Wardwright Contract Tests

`contract_probe.py` is the first shared HTTP contract and fuzz probe for the
backend prototypes. It intentionally uses only the Python standard library so
it can run before we choose a backend language or codegen stack.

Run a backend on `127.0.0.1:8787`, then:

```bash
python3 tests/contract_probe.py \
  --base-url http://127.0.0.1:8787 \
  --fuzz-runs 50
```

The probe checks:

- `GET /v1/models`
- `GET /v1/synthetic/models`
- `POST /v1/chat/completions`
- `POST /v1/synthetic/simulate`
- `GET /v1/receipts`
- `GET /v1/receipts/{receipt_id}`
- `GET /admin/providers`
- `GET /admin/storage`
- `GET /admin/synthetic-models`
- flat and `wardwright/` model namespace variants
- caller metadata precedence and receipt provenance
- basic latency percentiles

This is a behavioral gate, not a full OpenAPI validator. Later phases should
add generated OpenAPI schema tests, streaming-specific tests, property tests for
route graph invariants, and load/backpressure tests.

The probe fuzzes request size and content shape, but it does not currently
generate arbitrary OpenAPI-valid payloads, invalid request corpora, SSE stream
framing, provider failures, or policy-cache histories. Treat it as a smoke and
contract probe, not as coverage proof.

## Storage/Sink Contract

`storage_contract.py` is the first executable fixture for
`contracts/storage-provider-contract.md`. It currently tests reference memory
and JSON-file stores plus in-memory event/search/log sinks:

```bash
python3 tests/storage_contract.py --store all --cases 50
```

The fixture checks:

- storage health and migration metadata
- model-version immutability and rollback pointer behavior
- receipt insert/fetch/list/filter/retention behavior
- deterministic ordering when timestamps tie
- durable reopen for the JSON-file reference store
- event-stream idempotency and per-receipt ordering
- search projection filtering and rebuild from durable receipts
- log/telemetry redaction against forbidden prompt/completion/credential-like
  markers

Future SQLite, Postgres, search, and event-stream adapters should satisfy this
same behavior before being treated as viable product foundations.

## Generated Model/Governance Properties

`property_fuzz.py` generates random synthetic model definitions and validates
route-selection and stream-governance invariants against a local oracle.

Pure properties only:

```bash
python3 tests/property_fuzz.py --cases 500
```

Pure properties plus dynamic HTTP properties against a backend that supports the
prototype-only `POST /__test/config` endpoint:

```bash
python3 tests/property_fuzz.py \
  --base-url http://127.0.0.1:8787 \
  --cases 500 \
  --http-cases 100
```

The dynamic HTTP layer generates a model definition, installs it into the
backend, generates requests around context-window thresholds, and checks
selected targets, skipped targets, receipts, caller provenance, and latency
against the oracle.

Current generated space:

- 2-6 route targets per generated synthetic model
- random target context windows from 64 to 12,000 estimated tokens
- threshold requests at each context boundary and one token around it
- generated stream-rule markers for the pure buffered-horizon oracle
- generated request-policy markers with `escalate` governance actions
- fixed caller dimensions supplied through Wardwright headers

Current asserted properties:

- route selection picks the smallest context window that fits the estimate
- if no target fits, route selection falls back to the largest context window
- skipped targets are exactly the smaller windows that could not fit
- model IDs work in both flat and `wardwright/` prefixed namespaces
- receipts preserve selected model, skipped count, and caller provenance
- matching request governance records a policy action, alert count, and
  `policy.alert` event
- pure stream-governance oracle never releases a violating marker before its
  buffered horizon has had a chance to trigger

Current gaps:

- the stream-governance property is still a pure Python oracle; backend stream
  TTSR behavior is not implemented or contract-tested yet
- the generator is deterministic `random`, not Hypothesis/proptest with
  shrinking
- negative and malformed policy/config payload generation is shallow
- HTTP assertions check skipped count, but not the full skipped-target payload
- policy-cache/history semantics are documented, but not generated yet

As storage and sink adapters come online, the same generator should also build
sink oracles. For each generated request, tests should assert:

- the durable receipt store has the authoritative receipt and ordered events
- configured event streams receive the expected event IDs in per-receipt order
- configured search sinks expose the expected receipt summary and filters after
  a bounded eventual-consistency wait
- telemetry/log sinks receive redacted derived payloads, never raw prompt,
  completion, credential, or private-identifier fields by default
- replaying durable receipt events can rebuild derived search/log projections

Run dynamic-config tests against isolated backend instances, or run them
serially. `POST /__test/config` intentionally mutates prototype state, so
parallel probes against the same process can invalidate each other's model
namespace assumptions.

## Native Bakeoff Oracle Properties

The old Python/Hypothesis bakeoff suites were retired after the repository chose
the BEAM-first Wardwright app direction. Their useful pure oracles now live in
native StreamData tests under `app/test/bakeoff_oracle_property_test.exs`.

Those native properties cover:

- structured-output governance as a non-terminal guard loop, including guard
  count, guard type, attempt budget, eventual success, and budget exhaustion
- recent-history governance scoped to a single session/run, including
  out-of-scope isolation, irrelevant in-scope non-matches, deterministic
  eviction, and generated retained-event counts
- async alert sink behavior, including queue capacity, idempotency, dead-letter
  behavior, drop behavior, and fail-closed full queues

Run them with the normal app suite:

```bash
cd app
mix test
```

The backend-facing Python bakeoff tests were not carried forward because they
were designed to judge separate Go/Rust/Elixir bakeoff worktrees. New
Wardwright app behavior should be specified directly in ExUnit/StreamData tests,
with external Python kept for lightweight probes such as `contract_probe.py` and
`storage_contract.py`.

Mutation testing is available through Muex:

```bash
mise run mutation:app
```

Use mutation failures or surviving mutants to decide where native tests are too
shallow before treating a policy feature as complete.

Initial bounded sample result after adding Muex:

- 30 sampled mutants
- 12 killed
- 13 survived
- 5 invalid
- 48.0% mutation score

The first survivors clustered around policy-cache matching, route-selection
fallbacks, caller metadata fallback precedence, history-threshold receipt fields,
and a few broad router statement deletions. Treat those as the first under-tested
areas to harden, not as a merge blocker for the prototype rename.

## BDD Scenarios

`bdd_scenarios.py` is ordinary behavior-driven documentation as executable
tests. It prints Given/When/Then steps for normal product flows:

```bash
python3 tests/bdd_scenarios.py --base-url http://127.0.0.1:8787
```

Current scenarios:

- listing public synthetic models
- routing chat and recording a receipt
- simulating route selection before rollout
- rejecting unknown model names
- routing a generated test model by context window when the backend supports
  `POST /__test/config`
- recording an asynchronous policy alert event when a request guard matches

## Native App Tests

The visible contracts are intentionally backend-neutral. The active app needs
local tests for its own route, policy, and receipt implementation:

- endpoint behavior, receipt store behavior, policy alert/transform
  receipts, receipt filters, and invalid dynamic route configs.

CI should run these native tests before the Python contract probes.
