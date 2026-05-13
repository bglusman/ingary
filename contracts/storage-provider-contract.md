# Ingary Storage Provider Contract

Status: draft

This contract defines the behavior a storage implementation must provide to be
usable by an Ingary backend. It is intentionally independent of language,
database engine, and physical schema.

The contract is not an ORM API. It is a logical persistence boundary for
control-plane state, receipt/event history, retention, and UI query behavior.

## Integration Shapes

A storage provider can satisfy the contract in more than one form:

- **Native library adapter** compiled into a backend, such as Rust using SQLite
  directly.
- **Managed runtime adapter** inside a backend, such as Elixir using Ecto with
  Postgres.
- **Sidecar adapter** over localhost HTTP/gRPC/Unix socket for experiments that
  should be reusable across languages without FFI.
- **Remote service adapter** for hosted deployments, if auth, latency, and
  failure behavior are explicit.

The sidecar shape is the cleanest way to make one storage implementation usable
from every backend language during prototyping. Native adapters are still
valuable for the eventual production path where operational simplicity or
latency matters more than cross-language reuse.

The contract should therefore be testable through a small black-box fixture
suite. Language-native adapters can expose the fixture operations through a test
binary or test-only HTTP endpoint; sidecar adapters can expose them directly.

## Receipts, Events, Logs, And Storage

Receipts overlap with logs, but they should not be reduced to ordinary logs.
Ingary needs both concepts:

- **Receipts** are product records: queryable, versioned, retention-aware,
  privacy-aware, and tied to synthetic model behavior.
- **Receipt events** are ordered state-machine facts that build a receipt.
- **Logs** are operational diagnostics for humans and infrastructure.
- **Telemetry sinks** are external copies of selected receipt/log/metric events.

The storage contract owns the durable receipt and control-plane record. A log or
telemetry adapter can receive the same events, but it does not replace the
system of record unless it also satisfies the storage-provider contract.

This gives Ingary two related adapter surfaces:

- **Storage providers**: answer product queries, enforce retention, store
  model versions, and preserve receipt history.
- **Event/log sinks**: stream operational events to files, OpenTelemetry,
  Kafka-compatible queues, hosted observability tools, or audit pipelines.

The receipt writer should be modeled as an append path that can fan out to both:

1. append to the durable storage provider
2. emit a redacted event/log representation to configured sinks

Storage failure and log-sink failure have different semantics. If durable
receipt persistence is required, storage failure should fail closed or degrade
according to explicit operator policy. Log-sink failure should usually degrade
open with backpressure and drop/queue policy recorded in local health state.

## Goals

- Let Rust, Go, Elixir, and future backends test against the same storage
  behavior.
- Let SQLite, Postgres, and future stores evolve behind a stable logical
  contract.
- Keep database-specific schema design available where it helps durability,
  indexing, concurrency, or analytics.
- Make storage behavior measurable with the same BDD and property harness style
  used for backend HTTP behavior.

## Required Capabilities

### Health And Metadata

Storage providers must expose:

- provider kind, for example `memory`, `sqlite`, `postgres`, `duckdb`
- schema/storage contract version
- migration version
- read/write health
- optional capability flags

Capability flags should include:

- `durable`
- `transactional`
- `concurrent_writers`
- `json_queries`
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

- empty database initializes to the expected migration version
- previous migration upgrades without losing records
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

## Matrix Strategy

The prototype matrix should treat backend language and storage implementation as
orthogonal axes:

| Backend | Memory | SQLite | Postgres | Redis adjunct | DuckDB export |
|---|---:|---:|---:|---:|---:|
| Rust | required | required | candidate | optional | optional |
| Go | required | candidate | candidate | optional | optional |
| Elixir | required | candidate | candidate | optional | optional |

`Memory` remains useful for contract tests and development, but it must be
marked non-durable. SQLite is the first durable implementation to prove local
and embedded behavior. Postgres is the implementation that proves team/server
behavior.

The first useful storage prototype is a shared logical fixture suite that can
run against:

1. an in-process memory store
2. a SQLite database file
3. a Postgres test database or container

Only after those pass should Redis and DuckDB be evaluated, because they are
adjuncts rather than primary stores for the first product shape.
