# Wardwright

Wardwright is an experimental synthetic model platform generalized and extended from related ideas in Calciforge's
model-gateway work.

The core idea: clients call stable model names such as `coding-balanced` or
`wardwright/coding-balanced`, while Wardwright owns the route graph behind that name:
provider selection, context-window fit checks, fallback policy, stream
governance, caller traceability, and receipts explaining every decision.

The product is explicitly inspired by model-alloy work on alternating multiple
LLMs inside one agent context, plus oh-my-pi's TTSR pattern of stream-triggered
rule injection. Wardwright's first composition primitives are dispatchers,
cascades, and alloys; see `docs/synthetic-models.md`.

This repository used to keep multiple backend prototypes alive while Wardwright
selected a production foundation through shared contracts and measurable
behavior. The active implementation direction is now BEAM-first: Elixir owns
runtime plumbing and LiveView, while Gleam is the preferred home for
correctness-heavy pure policy logic when the boundary is stable enough.

## Current Contents

- `contracts/openapi.yaml` - draft HTTP/OpenAI-compatible contract.
- `contracts/storage-provider-contract.md` - draft storage behavior contract.
- `contracts/tool-context-policy-contract.md` - research-spike contract for
  policy selection by normalized tool context.
- `app` - active Elixir/Phoenix LiveView application, including Gleam policy
  core modules under `app/src/wardwright`.
- `docs/rfcs/wardwright-extraction.md` - product and architecture draft.
- `docs/` - public docs site for `wardwright.dev`.

## Current Test State

Dynamic generated model properties require the prototype-only
`POST /__test/config` endpoint. It exists while the production configuration API
is still being designed, but it is disabled by default outside tests. Enable it
only for controlled local runs with `WARDWRIGHT_ALLOW_TEST_CONFIG=1`.

Run the active native suite with:

```bash
(cd app && mise exec -- mix format --check-formatted && mise exec -- mix test)
```

## Local Development

Run the active app:

```bash
(cd app && WARDWRIGHT_BIND=127.0.0.1:8791 mise exec -- mix run --no-halt)
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
