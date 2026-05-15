# Wardwright Storage Provider Contract

Status: draft

This contract defines the behavior a storage implementation must provide to be
usable by a Wardwright backend. It is intentionally independent of runtime,
database engine, and physical schema.

The contract is not an ORM API. It is a logical persistence boundary for
control-plane state, receipt/event history, retention, and UI query behavior.

## Integration Shapes

A storage provider can satisfy the contract in more than one form:

- **In-process runtime store** for hot request-path state, such as supervised
  BEAM processes and ETS tables. This shape is fast and operationally simple,
  but it is not durable by itself.
- **File-backed durable provider** for local installs, using append-only receipt
  events plus deterministic snapshots/checkpoints.
- **BEAM-native durable provider** for deployments where Mnesia's transactions,
  replication, and runtime integration are a better fit than an external
  database.
- **Database provider** for deployments that need richer SQL query, migration,
  external tooling, or operational features, such as SQLite or Postgres.
- **Sidecar adapter** over localhost HTTP/gRPC/Unix socket for experiments that
  should be reusable without binding the active app to one storage engine.
- **Remote service adapter** for hosted deployments, if auth, latency, and
  failure behavior are explicit.

The active app is BEAM-first, so ETS/process state is expected on the hot path.
Durability should be proven first through the smallest provider that can satisfy
this contract. A database is valuable when it buys behavior the product needs;
it should not be assumed just because data exists.

The contract should therefore be testable through a small black-box fixture
suite. Language-native adapters can expose the fixture operations through a test
binary or test-only HTTP endpoint; sidecar adapters can expose them directly.

## Receipts, Events, Logs, And Storage

Receipts overlap with logs, but they should not be reduced to ordinary logs.
Wardwright needs both concepts:

- **Receipts** are product records: queryable, versioned, retention-aware,
  privacy-aware, and tied to synthetic model behavior.
- **Receipt events** are ordered state-machine facts that build a receipt.
- **Logs** are operational diagnostics for humans and infrastructure.
- **Telemetry sinks** are external copies of selected receipt/log/metric events.
- **Search indexes** are derived query surfaces for high-cardinality text,
  faceted exploration, and dashboard search.
- **Event streams** are append-only transport and buffering layers for receipt,
  log, and metric events.

The storage contract owns the durable receipt and control-plane record. A log or
telemetry adapter can receive the same events, but it does not replace the
system of record unless it also satisfies the storage-provider contract.

This gives Wardwright two related adapter surfaces:

- **Storage providers**: answer product queries, enforce retention, store
  model versions, and preserve receipt history.
- **Event/log sinks**: stream operational events to files, OpenTelemetry,
  Kafka-compatible queues, hosted observability tools, or audit pipelines.
- **Search sinks**: index receipt summaries, event metadata, and optional
  redacted content for operator search.
- **Analytics/database sinks**: receive larger derived datasets for warehouse,
  BI, audit, customer reporting, or offline evaluation use cases.

The receipt writer should be modeled as an append path that can fan out to both:

1. append to the durable storage provider
2. emit a redacted event/log representation to configured sinks
3. update derived search indexes when configured

Storage failure and log-sink failure have different semantics. If durable
receipt persistence is required, storage failure should fail closed or degrade
according to explicit operator policy. Log-sink failure should usually degrade
open with backpressure and drop/queue policy recorded in local health state.
Search-index failure should not corrupt the receipt store; it should mark the
index stale and allow a rebuild from durable receipts/events.

Because sinks are derived from the same receipt-event stream, they are part of
the property testing surface. A generated request should produce an expected
receipt oracle and an expected sink oracle:

- storage contains the authoritative receipt and ordered event timeline
- event-stream sinks receive the expected events in order, or expose explicit
  retry/drop/backpressure state
- search sinks eventually expose the expected indexed receipt summary and
  allowed redacted fields
- telemetry/log sinks contain no prompt, completion, credential, or private
  identifier fields unless explicitly configured and redacted
- replaying durable receipt events can rebuild derived search indexes

The sink oracle should allow eventual consistency where the sink is asynchronous,
but it must bound that wait and make missing/stale sink records visible.

Candidate infrastructure roles:

- **Elasticsearch/OpenSearch/Meilisearch/Typesense**: search sinks for receipt
  explorer, faceted filtering, text search over redacted artifacts, and
  dashboard-style exploration. They are not the authoritative model-definition
  store unless wrapped by a provider that satisfies this storage contract.
- **Kafka/Redpanda/Iggy/NATS JetStream**: event-stream sinks for fanout,
  buffering, replay, async indexing, warehouse export, and audit pipelines. They
  are not by themselves the queryable receipt store unless paired with a
  materialized store that satisfies this contract.
- **OpenTelemetry/log files/hosted observability**: operational diagnostics and
  metrics. They are useful outputs, not the source of truth.
- **Mnesia/SQLite/Postgres/DuckDB/warehouse exports**: possible durable providers or
  derived analytics sinks depending on deployment shape. The distinction must
  be explicit because a database can be the source of truth, a projection, or a
  reporting target.

## Goals

- Let the active BEAM app and future storage engines test against the same
  storage behavior.
- Let ETS, file-backed providers, Mnesia, SQLite, Postgres, and future stores
  evolve behind a stable logical contract.
- Keep database-specific schema design available where it helps durability,
  indexing, concurrency, or analytics.
- Make storage behavior measurable with the same BDD and property harness style
  used for backend HTTP behavior.

## Required Capabilities

### Health And Metadata

Storage providers must expose:

- provider kind, for example `ets`, `file`, `mnesia`, `sqlite`, `postgres`,
  `duckdb`
- schema/storage contract version
- migration version
- read/write health
- optional capability flags

Capability flags should include:

- `durable`
- `runtime_hot_store`
- `transactional`
- `concurrent_writers`
- `json_queries`
- `full_text_search`
- `faceted_search`
- `event_replay`
- `consumer_offsets`
- `time_range_indexes`
- `retention_jobs`
- `advisory_locks`
- `analytics_exports`

### Control Plane

Storage providers must support:

- create and fetch provider definitions
- create and fetch concrete model definitions
- create synthetic model records
- create immutable synthetic model versions
- activate draft/canary/rollback rollout state
- import synthetic model artifacts with provenance and review state
- reject mutation of already-activated model versions

### Receipts

Storage providers must support:

- insert one complete receipt with ordered events atomically
- fetch receipt by ID
- list receipt summaries in stable reverse-chronological order
- preserve receipt schema version
- preserve caller identifiers and source/provenance labels
- preserve selected target, skipped targets, provider attempts, stream triggers,
  final status, latency, token, and cost fields
- support live and simulated receipt records

### Query Behavior

Receipt queries must support filtering by:

- tenant ID
- application ID
- consuming agent ID
- consuming user ID
- session ID
- run ID
- synthetic model ID
- synthetic model version ID
- selected provider
- selected concrete model
- final status
- simulation/live flag
- stream-policy action
- time range

Queries must support deterministic pagination. Cursor pagination is preferred
for production stores. Offset pagination is acceptable for prototypes.

### Retention And Privacy

Storage providers must support separate retention behavior for:

- receipt metadata
- receipt events
- optional prompt/completion/tool-call artifacts

Prompt and completion content must not be stored unless content capture is
explicitly enabled by configuration. If content artifacts are stored, the
storage provider must persist the redacted form produced by the gateway, not raw
pre-redaction content.

Retention must not delete the minimum metadata needed to explain why a route
decision happened unless the operator explicitly configures full deletion.

### Export

Durable providers should support export of receipt metadata and events to a
stable NDJSON shape. Parquet-compatible export is desirable but not required for
MVP 1.

DuckDB can be used as an export/analysis target, but a DuckDB-backed provider
must still satisfy the request-path durability and concurrency contract before
being considered a primary store.

## Minimum Behavioral Tests

Every storage provider implementation should pass these tests:

- empty durable store initializes to the expected storage version
- previous durable format or migration upgrades without losing records
- receipt insert and fetch round-trip preserves all contract fields
- receipt list ordering is stable when timestamps tie
- caller filters return the same receipts as an in-memory oracle
- model/version/status/provider/time filters return the same receipts as an
  in-memory oracle
- simulated and live receipts can be queried independently
- activated model versions cannot be mutated
- rollback changes active rollout pointer without mutating version history
- retention deletes optional artifacts without deleting required receipt
  metadata
- provider restart preserves durable records
- optional Redis loss does not lose durable model, rollout, or receipt state
- optional search-index loss can be rebuilt from durable receipts/events
- optional event-stream outage follows explicit queue/drop/backpressure policy

Every configured sink should pass these tests:

- receipt-event fanout emits exactly the expected event IDs for a generated
  request
- event order is preserved per receipt/run where the sink claims ordered
  delivery
- at-least-once sinks use idempotency keys so duplicate delivery does not create
  duplicate derived search records
- redaction policy is identical between durable storage artifacts and sink
  payloads
- sink health exposes lag, queue depth, stale index status, and last successful
  checkpoint where applicable
- replay from durable receipt events rebuilds the sink to the same observable
  state as live fanout

## Provider Strategy

The current prototype should treat authoritative state and high-volume sinks as
separate axes:

| Surface | ETS/process state | File-backed store | Mnesia/SQL store | Search sink | Event stream | Database/warehouse sink |
|---|---:|---:|---:|---:|---:|---:|
| Request-path model/session state | required | optional snapshot | candidate | no | optional events | no |
| Receipt and policy history | candidate cache | first durable target | candidate | derived | derived | derived |
| Operator search | no | rebuild source | candidate source | candidate | optional feed | optional |
| Analytics/evaluation | no | export source | candidate | optional | candidate feed | candidate |

ETS remains useful for runtime state, contract tests, and development, but it
must be marked non-durable unless paired with a durable provider. A file-backed
append log plus snapshots is the likely first durable implementation because it
keeps local installs simple and makes replay behavior easy to test. Mnesia,
SQLite, and Postgres should remain behind the same contract and become primary
candidates when they clearly improve BEAM-native durability, concurrency,
querying, migrations, hosted operations, or external reporting.

The first useful storage prototype is a shared logical fixture suite that can
run against:

1. an in-process ETS/runtime store, explicitly non-durable
2. a file-backed append-log/snapshot provider
3. optional Mnesia/SQLite/Postgres providers when the product has a concrete
   durability, query, or deployment reason to test

Redis, DuckDB, search engines, event streams, and warehouse/database sinks can be
evaluated earlier when the feature is explicitly about fanout, analytics,
search, or backpressure. They should still be treated as adjuncts or derived
surfaces unless the selected implementation also satisfies the authoritative
storage-provider contract.
