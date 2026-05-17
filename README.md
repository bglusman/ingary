# Wardwright

Wardwright is an experimental synthetic model platform generalized and extended from related ideas in Calciforge's
model-gateway work.

The core idea: clients call stable model names such as `coding-balanced` or
`wardwright/coding-balanced`, while Wardwright owns the route graph behind that
name: provider selection, context-window fit checks, fallback policy, stream
governance, caller traceability, policy simulation, and receipts explaining
every decision.

The product is explicitly inspired by model-alloy work on alternating multiple
LLMs inside one agent context, plus oh-my-pi's TTSR pattern of stream-triggered
rule injection. Wardwright's first composition primitives are dispatchers,
cascades, and alloys; see `docs/synthetic-models.md`.

This repository used to keep multiple backend prototypes alive while Wardwright
selected a production foundation through shared contracts and measurable
behavior. The active implementation direction is now BEAM-first: Elixir owns
runtime plumbing and LiveView, while Gleam is the preferred home for
correctness-heavy pure policy logic when the boundary is stable enough.

## Install

Wardwright publishes early native binaries for macOS and Linux. The next
prepared release is `v0.0.4`.

### macOS Homebrew

```bash
brew tap bglusman/tap
brew install wardwright
brew services start wardwright
```

The Homebrew service binds to `127.0.0.1:8787` by default and creates local
configuration, data, and log directories under Homebrew-managed paths. Open the
policy workbench after the service starts:

```bash
open http://127.0.0.1:8787/policies
```

For one-shot foreground testing instead of a service:

```bash
WARDWRIGHT_SECRET_KEY_BASE="$(cat "$(brew --prefix)/etc/wardwright/secret_key_base")" \
WARDWRIGHT_BIND=127.0.0.1:8787 \
wardwright
```

### Linux Tarball

The installer downloads the matching GitHub Release archive, verifies it against
`checksums-sha256.txt`, and installs `wardwright` to `~/.local/bin` by default.

```bash
curl -fsSL https://raw.githubusercontent.com/bglusman/wardwright/main/scripts/install.sh | sh
```

For a pinned release:

```bash
curl -fsSL https://raw.githubusercontent.com/bglusman/wardwright/main/scripts/install.sh | sh -s -- --version v0.0.4
```

Run it locally:

```bash
WARDWRIGHT_SECRET_KEY_BASE="$(openssl rand -base64 64)" \
WARDWRIGHT_BIND=127.0.0.1:8787 \
~/.local/bin/wardwright
```

Then visit `http://127.0.0.1:8787/policies`. Set `WARDWRIGHT_ADMIN_TOKEN` before
exposing Wardwright beyond loopback.

### Operator Helpers

The installed binary also exposes small discovery commands for local agents and
operators:

```bash
wardwright --help
wardwright tools
wardwright tools --json
```

See [Packaging](docs/packaging.md) for release targets, manual archive install
steps, and service details.

## Current Contents

- `contracts/openapi.yaml` - draft HTTP/OpenAI-compatible contract.
- `contracts/storage-provider-contract.md` - draft storage behavior contract.
- `app` - active Elixir/Phoenix LiveView application, including Gleam policy
  core modules under `app/src/wardwright`.
- `docs/rfcs/wardwright-extraction.md` - product and architecture draft.
- `docs/` - public docs site for `wardwright.dev`.

## Current Runtime Shape

The active app exposes:

- OpenAI-compatible `/v1/chat/completions` and `/v1/models` endpoints.
- Synthetic model route planning with dispatchers, cascades, alloys, fallback
  policy, and context-window fit checks.
- Request, route, stream, output, history, alert, and tool-context policy
  primitives.
- Streaming TTSR-style governance with bounded buffering, regex/literal
  triggers, safe-prefix release, retries with reminders, rewrites, and receipt
  evidence.
- ETS-backed hot policy history plus protected authoring, simulation, receipt,
  and admin surfaces.
- A Phoenix LiveView policy workbench at `/policies` with projection diagrams,
  simulation playback, recipe selection, state-machine views, route/effect
  summaries, and tool-governance demos.

Wardwright is still an early prototype. Interfaces are intentionally more
important than deep implementation maturity, and unsupported inputs should fail
loudly or be documented as prototype limitations.

## Development And Tests

Dynamic generated model properties require the prototype-only
`POST /__test/config` endpoint. It exists while the production configuration API
is still being designed, but it is disabled by default outside tests. Enable it
only for controlled local runs with `WARDWRIGHT_ALLOW_TEST_CONFIG=1`.

Run the active native suite with:

```bash
(cd app && mise exec -- mix format --check-formatted && mise exec -- mix test)
```

Live provider smoke tests are outside the default suite. Configure at least one
target, then run:

```bash
WARDWRIGHT_LIVE_OLLAMA_MODEL=qwen2.5-coder:latest mise run test:live-providers

WARDWRIGHT_LIVE_OPENAI_MODEL=gpt-4.1-mini \
WARDWRIGHT_LIVE_OPENAI_BASE_URL=https://api.openai.com/v1 \
WARDWRIGHT_LIVE_OPENAI_API_KEY=... \
mise run test:live-providers
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
