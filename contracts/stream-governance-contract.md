# Stream Governance Contract

This contract defines the pure simulator semantics for time-travel stream
reactions. It is intentionally narrower than the future production runtime so
that generated policy tests, UI simulations, and backend implementations can
agree on observable behavior before provider streaming is wired in.

## TTSR Rule Shape

A time-travel stream reaction rule contains:

- `id`
- matcher kind: `literal` or `regex`
- matcher pattern
- `horizon_bytes`
- action: initially `retry_with_reminder`
- `max_retries`
- retry violation behavior: initially `block_final`

The simulator treats the rule as a detector plus proposed action. Runtime
mutation is performed by the deterministic stream arbiter, not directly by the
detector.

## Buffered Horizon Semantics

Provider output is normalized into ordered text chunks. For each attempt:

1. Append the next chunk to the held stream window.
2. Evaluate the matcher against the held window.
3. If the matcher trips, abort the attempt before releasing the matched text.
4. If no matcher trips and the held window exceeds `horizon_bytes`, release
   whole UTF-8 codepoints until the held window is within the horizon.
5. At normal completion, release the remaining held text.

For literal rules, `horizon_bytes` must be at least the UTF-8 byte length of the
literal pattern to guarantee that the complete trigger can be detected before
any trigger byte is released. A shorter horizon is a simulator counterexample,
not an acceptable production policy.

Regex rules are simulated with the same validated regex subset exposed by the
native BEAM policy engine. Regex authoring should reject or warn on patterns
whose future-match intent cannot fit inside the configured horizon.

## Retry And Block Semantics

When a rule triggers:

- the current provider stream attempt is aborted
- the receipt preview records `stream.rule_matched`
- the matched span is marked `released_to_consumer: false`
- if retries remain, the next attempt starts with the configured reminder
- if a retry attempt triggers again, final output is blocked and the receipt
  preview records `stream.blocked`

The pure simulator does not call providers and does not produce replacement
text. It consumes caller-provided attempt streams so UI and property tests can
model retry success or retry violation deterministically.

The production runtime must sit behind a supervised provider boundary with
explicit timeouts before live streaming replaces mock attempt streams.
Non-streaming provider timeout failures surface as `provider_error` receipts.
The current BEAM evaluator supports opt-in bounded holdback through
`horizon_bytes` or `holdback_bytes` on stream rules. When every active stream
rule declares a horizon, old safe bytes can be released while the most recent
window stays available for split-boundary matching. If any active rule omits a
horizon, the evaluator keeps the older full-buffer behavior so it does not
pretend an unbounded rule is safe to stream past.

The evaluator also exposes an incremental arbiter API: initialize policy state,
consume one normalized provider chunk, receive the newly releasable text chunks,
and finish the stream to flush any remaining held suffix. That API is the
contract boundary used by the router/runtime streaming state machine.

The BEAM runtime now drives that arbiter while provider chunks arrive. Bounded
horizon rules may release safe prefixes over SSE before the full provider stream
finishes. If a later chunk trips a block rule, Wardwright cancels the provider
attempt, sends a terminal stream-policy SSE event when headers have already been
sent, and records the held/blocked bytes in the receipt. If no bytes have been
released yet, Wardwright can still return fail-closed JSON with the policy
status.

Retry semantics remain intentionally conservative. A `retry` or
`retry_with_reminder` action may restart an attempt before any bytes are sent to
the client. Once bytes have been released, Wardwright cannot invisibly rewind the
client stream; the runtime records the terminal policy event instead of
pretending the failed attempt can be erased.

## Generated Simulation Cases

Shared property probes must cover at least:

- trigger split across chunks
- trigger at the holdback boundary
- literal and regex triggers
- near misses that release normally
- retry violation followed by final block
- too-short horizon counterexamples

Simulator output must be suitable for a user-facing counterexample viewer:

- scenario name and rule summary
- chunk timeline
- release and hold timeline
- trigger span and matched rule
- retry count
- final status
- receipt event preview
