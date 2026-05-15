# Policy Cache Contract

The policy cache is a bounded, in-memory history surface for facts that policy
rules may inspect during request evaluation. It is not the durable receipt
store and must not become an ambient log of prompts or completions.

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

## Recent History API

`GET /v1/policy-cache/recent` supports `kind`, `key`, caller-scope query fields
such as `session_id`, and `limit`. Results must not exceed `recent_limit`.

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
