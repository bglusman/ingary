# Policy Cache Contract

The policy cache is a bounded, in-memory history surface for facts that policy
rules may inspect during request evaluation. The BEAM implementation owns this
hot state in ETS behind `Wardwright.PolicyCache`. It is not the durable receipt
store and must not become an ambient log of prompts or completions.

The current prototype exposes this as one logical cache API. The intended
runtime shape is more granular:

- one low-write session catalog for active session metadata and table
  references
- one bounded ordered ETS table per active session for session-local history
- separate aggregate/index tables for policies that intentionally read across
  sessions, callers, models, or tenants

Policy code must request named scopes and facts through this contract rather
than discovering ETS table names or references directly.

## Configuration

Synthetic model config may include:

```json
{
  "policy_cache": {
    "max_entries": 64,
    "recent_limit": 20
  }
}
```

- `max_entries` is the hard cap for retained events.
- `recent_limit` caps query results returned by the recent-history API.
- Replacing test config clears the cache, so policy tests do not inherit stale
  history.
- Writes publish a redacted `policy_cache.event_recorded` event on the runtime
  policy PubSub topic so LiveView can monitor active history without polling.

Per-session history tables may use independent caps derived from model policy
configuration. Aggregate indexes must declare their own retention and
consistency behavior; they must not inherit session retention implicitly.

## Event Shape

`POST /v1/policy-cache/events` accepts:

```json
{
  "kind": "tool_call",
  "key": "shell:ls",
  "scope": {"session_id": "example-session"},
  "value": {"status": "same-result"},
  "created_at_unix_ms": 0
}
```

The response is `201` with an `event` object containing a monotonic `sequence`.
The timestamp is caller-provided cache data. A value of `0` is valid and must
not be replaced with wall-clock time.

## Eviction

Eviction is deterministic:

1. Sort by `created_at_unix_ms`, then `sequence`.
2. Remove the oldest entries until `len(events) <= max_entries`.
3. Recent queries return surviving entries newest-sequence first.

This makes eviction property-testable without depending on process time.
The cache must report its active cap and entry count so operators can see
whether history-driven policy rules are working from a small recent window or a
larger local memory horizon.

## Recent History API

`GET /v1/policy-cache/recent` supports `kind`, `key`, caller-scope query fields
such as `session_id`, and `limit`. Results must not exceed `recent_limit`.

Session-scoped queries should read the session-local table when a session is
known. Cross-session queries should read declared aggregate/index tables, not
fan out across all active session tables on the request path. Fanout over the
session catalog is acceptable for debug views, simulation, migration tooling, or
small explicitly bounded experiments, but it is not the default enforcement
path.

Policies may declare that they never read outside their own session, only read
outside their own session, or read both. Wardwright must make that distinction
visible in configuration, receipts, and operator UI so users can understand the
cost, privacy boundary, and latency risk of each rule.

## ETS Ownership Model

The BEAM hot-path implementation should use ETS as an implementation detail
behind supervised runtime processes:

- A catalog owner process writes the active-session catalog. Readers may inspect
  it for UI/runtime visibility.
- Each session runtime owns its session history table and serializes writes for
  that session only. This preserves stream order and prevents one busy session
  from backpressuring unrelated session history writes.
- Aggregate/index owners write derived cross-session policy facts. These owners
  can be sharded by model, tenant, rule, or time window if telemetry shows
  write pressure.
- ETS table references are runtime capabilities. Dynamic per-session tables
  should be anonymous table IDs stored in the catalog, not dynamically generated
  named atoms.

Read APIs should prefer direct ETS reads for stable, bounded facts and avoid
synchronous GenServer calls for high-frequency reads. Writes, eviction, and
projection updates remain owned by their responsible runtime process so ordering
and lifecycle are explicit.

## Observability Requirements

The policy cache surface must expose enough status for operators and LiveView
tools to tell which history design is active:

- active session count and per-session retained event counts
- configured session caps and aggregate/index caps
- aggregate/index lag or stale status when projection is asynchronous
- catalog owner, session owner, and index owner health
- whether a rule reads current-session history, cross-session aggregates, or
  both

Receipts for history-aware decisions should identify the fact source, scope,
window, count, and retention limit used for the decision. A rule that depends
on unavailable or stale deterministic history must fail closed according to its
configured enforcement policy rather than silently scanning a broader store.

## Built-In Policy Rule

The initial cache-reading governance rule is:

```json
{
  "id": "repeat-tool",
  "kind": "history_threshold",
  "action": "escalate",
  "cache_kind": "tool_call",
  "cache_key": "shell:ls",
  "cache_scope": "session_id",
  "threshold": 2
}
```

During request policy evaluation, Wardwright counts matching cache events in the
configured caller scope. `escalate` records a `policy.alert` receipt event and
includes `history_count` and `threshold` in `policy_actions`.
