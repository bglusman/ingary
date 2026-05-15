# Ingary

Ingary is an experimental synthetic model platform extracted from Calciforge's
model-gateway work.

The core idea: clients call stable model names such as `coding-balanced` or
`ingary/coding-balanced`, while Ingary owns the route graph behind that name:
provider selection, context-window fit checks, fallback policy, stream
governance, caller traceability, and receipts explaining every decision.

This repository used to keep multiple backend prototypes alive while Ingary
selected a production foundation through shared contracts and measurable
behavior. The active implementation direction is now BEAM-first: Elixir owns
runtime plumbing and LiveView, while Gleam is the preferred home for
correctness-heavy pure policy logic when the boundary is stable enough.

## Current Contents

- `contracts/openapi.yaml` - draft HTTP/OpenAI-compatible contract.
- `contracts/storage-provider-contract.md` - draft storage behavior contract.
- `tests/contract_probe.py` - dependency-free cross-backend HTTP probe.
- `tests/storage_contract.py` - executable storage/sink behavior fixture.
- `app` - active Elixir/LiveView backend prototype.
- `frontend/web` - Vite/React UI prototype.
- `docs/rfcs/ingary-extraction.md` - product and architecture draft.
- `docs/` - public docs site for `ingary.org`.

## Shared Contract Probe

Run a backend on `127.0.0.1:8787`, then:

```bash
python3 tests/contract_probe.py \
  --base-url http://127.0.0.1:8787 \
  --fuzz-runs 50
```

The probe checks the common OpenAI-compatible and Ingary-specific surface:

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

Run the active backend and UI:

```bash
# Elixir
(cd app && INGARY_BIND=127.0.0.1:8791 mix run --no-halt)

# Frontend
(cd frontend/web && npm run dev -- --host 127.0.0.1)
```

The backend also exposes the LiveView policy projection workbench at
`/policies`.

## Storage Direction

Ingary should treat storage as part of the product contract:

- SQLite is the default local and embedded store.
- Postgres is the intended team/server deployment store.
- Redis is optional ephemeral infrastructure only.
- DuckDB is a likely analytics/export companion, not the live request-path
  system of record.
- Elasticsearch/OpenSearch-style systems are likely derived search indexes.
- Kafka/Redpanda/Iggy-style systems are likely event streams for fanout,
  replay, async indexing, and audit pipelines.

The durable schema should keep frequently filtered receipt dimensions in
structured indexed columns and reserve JSON for versioned payloads and
provider-specific details. See `docs/rfcs/ingary-extraction.md` for the current
data-model plan and `contracts/storage-provider-contract.md` for the behavioral
contract storage implementations should satisfy.

Receipts, logs, search indexes, and event streams are related but separate
surfaces: storage providers are the queryable system of record, while event/log
sinks and search indexes receive redacted derived copies for observability,
exploration, replay, and audit pipelines.

## License

Apache-2.0.
