# Ingary

Ingary is an experimental synthetic model platform extracted from Calciforge's
model-gateway work.

The core idea: clients call stable model names such as `coding-balanced` or
`ingary/coding-balanced`, while Ingary owns the route graph behind that name:
provider selection, context-window fit checks, fallback policy, stream
governance, caller traceability, and receipts explaining every decision.

This repository is intentionally prototype-heavy right now. The goal is to pick
a foundation using a shared HTTP contract and measurable behavior rather than
choosing a language from preference alone.

## Current Contents

- `contracts/openapi.yaml` - draft HTTP/OpenAI-compatible contract.
- `contracts/storage-provider-contract.md` - draft storage behavior contract.
- `tests/contract_probe.py` - dependency-free cross-backend HTTP probe.
- `tests/storage_contract.py` - executable storage/sink behavior fixture.
- `prototypes/backends/rust-ingary` - clean Rust backend prototype.
- `prototypes/backends/go-ingary` - clean Go backend prototype.
- `prototypes/backends/elixir-ingary` - clean Elixir backend prototype.
- `prototypes/backends/litellm-spike` - LiteLLM foundation/integration spike.
- `prototypes/backends/tensorzero-spike` - TensorZero foundation/integration spike.
- `prototypes/frontend/web` - Vite/React UI prototype.
- `docs/rfcs/ingary-extraction.md` - product and architecture draft.
- `docs/rfcs/ingary-presentation.html` - self-contained HTML presentation.

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

## Current Prototype Test State

| Prototype | BDD scenarios | Baseline contract probe | Dynamic generated model properties |
|---|---:|---:|---:|
| Go | Passing | Passing | Passing |
| Rust | Passing | Passing | Not implemented yet |
| Elixir | Passing | Passing | Not implemented yet |

Dynamic generated model properties require the prototype-only
`POST /__test/config` endpoint. Go implements that first so the test shape can
stabilize before porting it to Rust and Elixir.

Run the storage/sink reference fixture with:

```bash
python3 tests/storage_contract.py --store all --cases 50
```

## Local Backend Matrix

For side-by-side frontend testing, run the prototypes on separate ports:

```bash
# Go
(cd backends/go-ingary && go run .)

# Rust
(cd backends/rust-ingary && INGARY_BIND=127.0.0.1:8797 cargo run)

# Elixir
(cd backends/elixir-ingary && INGARY_BIND=127.0.0.1:8791 mix run --no-halt)

# Frontend
(cd frontend/web && npm run dev -- --host 127.0.0.1)
```

The frontend at `http://127.0.0.1:5173` has a temporary backend selector for:

- Go: `http://127.0.0.1:8787`
- Rust: `http://127.0.0.1:8797`
- Elixir: `http://127.0.0.1:8791`

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
