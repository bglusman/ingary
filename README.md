# Wardwright

Wardwright is an experimental synthetic model platform extracted from Calciforge's
model-gateway work.

The core idea: clients call stable model names such as `coding-balanced` or
`ingary/coding-balanced`, while Wardwright owns the route graph behind that name:
provider selection, context-window fit checks, fallback policy, stream
governance, caller traceability, and receipts explaining every decision.

This repository used to keep multiple backend prototypes alive while Wardwright
selected a production foundation through shared contracts and measurable
behavior. The active implementation direction is now BEAM-first: Elixir owns
runtime plumbing and LiveView, while Gleam is the preferred home for
correctness-heavy pure policy logic when the boundary is stable enough.

## Current Contents

- `contracts/openapi.yaml` - draft HTTP/OpenAI-compatible contract.
- `contracts/storage-provider-contract.md` - draft storage behavior contract.
- `tests/contract_probe.py` - dependency-free cross-backend HTTP probe.
- `tests/storage_contract.py` - executable storage/sink behavior fixture.
- `app` - active Elixir/Phoenix LiveView application.
- `docs/rfcs/ingary-extraction.md` - product and architecture draft.
- `docs/` - public docs site for `ingary.org`.

## Shared Contract Probe

Run the app on `127.0.0.1:8791`, then:

```bash
python3 tests/contract_probe.py \
  --base-url http://127.0.0.1:8791 \
  --fuzz-runs 50
```

The probe checks the common OpenAI-compatible and Wardwright-specific surface:

- `GET /v1/models`
- `GET /v1/synthetic/models`
- `POST /v1/chat/completions`
- `POST /v1/synthetic/simulate`
- `GET /v1/receipts`
- `GET /v1/receipts/{receipt_id}`
- `GET /admin/providers`
- `GET /admin/storage`
- `GET /admin/synthetic-models`
- flat and `ingary/` model namespace variants
- caller provenance and receipt fields
- basic latency percentiles

## Current Test State

The old Go and Rust backend prototypes remain available in git history, but
they are no longer part of the live tree or local verification gate. The active
backend is `app`.

Dynamic generated model properties require the prototype-only
`POST /__test/config` endpoint. It exists while the production configuration API
is still being designed.

Run the storage/sink reference fixture with:

```bash
python3 tests/storage_contract.py --store all --cases 50
```

## Local Development

Run the active app:

```bash
(cd app && INGARY_BIND=127.0.0.1:8791 mise exec -- mix run --no-halt)
```

The app exposes both the OpenAI-compatible HTTP surface and the LiveView policy
projection workbench at `/policies`.

## Storage Direction

Wardwright should treat storage as part of the product contract:

- ETS and supervised processes are the expected hot runtime state for route
  health, model/session workers, short-lived policy state, and fast receipt
  updates.
- The first durable provider should likely be file-backed: append-only receipt
  events plus deterministic snapshots/checkpoints. That keeps local installs
  simple while the data model is still moving.
- Mnesia, SQLite, and Postgres remain candidate storage providers, but they
  should be justified by concrete needs such as BEAM-native replication,
  multi-writer coordination, ad hoc query surfaces, hosted/team deployments,
  migrations, or external reporting.
- Phoenix PubSub should carry live visibility events for LiveView and cluster
  projections early. It is a visibility bus, not an excuse for arbitrary
  cross-node mutation of a live session, and multi-node delivery still needs
  explicit clustering configuration.
- Redis is optional ephemeral infrastructure only.
- DuckDB, warehouses, and database sinks are likely analytics/export companions,
  not automatically the live request-path system of record.
- Elasticsearch/OpenSearch-style systems are likely derived search indexes.
- Kafka/Redpanda/Iggy/NATS-style systems are likely event streams for fanout,
  replay, async indexing, and audit pipelines.

The durable provider should keep frequently filtered receipt dimensions in a
structured shape and reserve opaque payloads for versioned details. The sink
surface should be able to move much larger derived data volumes than the local
authoritative store, with explicit redaction, replay, backpressure, and failure
semantics. See `contracts/storage-provider-contract.md` for the behavioral
contract storage providers and sinks should satisfy.

## License

Apache-2.0.
