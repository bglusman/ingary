# Ingary Contract Tests

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
- `POST /v1/chat/completions`
- `POST /v1/synthetic/simulate`
- `GET /v1/receipts`
- `GET /v1/receipts/{receipt_id}`
- `GET /admin/providers`
- `GET /admin/synthetic-models`
- flat and `ingary/` model namespace variants
- caller metadata precedence and receipt provenance
- basic latency percentiles

This is a behavioral gate, not a full OpenAPI validator. Later phases should
add generated OpenAPI schema tests, streaming-specific tests, property tests for
route graph invariants, and load/backpressure tests.

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
