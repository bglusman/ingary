# Wardwright App

Elixir/LiveView implementation of the Wardwright synthetic model platform contract.
It serves the OpenAI-compatible gateway surface, synthetic-model routing,
stream policy, receipts, protected authoring APIs, and the LiveView policy
workbench. Tests still rely heavily on mock providers, but the runtime boundary
is shaped for real provider adapters and local Ollama/OpenAI-compatible targets.

Gleam is compiled inside the same Mix project for small, correctness-heavy
policy decisions. Elixir keeps ownership of HTTP, Phoenix, processes, PubSub,
and mutable state; Gleam modules under `src/wardwright` own pure structured
output, history-threshold, and alert-queue classifications behind Elixir wrapper
modules in `lib/wardwright/policy`.

## Run

For packaged beta installs, use the root [README](../README.md) or
[Packaging](../docs/packaging.md). This app README is for source development.

```bash
cd app
mise exec -- mix deps.get
mise exec -- mix run --no-halt
```

The server binds to `127.0.0.1:8787` by default. Override with:

```bash
WARDWRIGHT_BIND=127.0.0.1:8788 mise exec -- mix run --no-halt
```

Smoke check:

```bash
curl http://127.0.0.1:8787/v1/models

curl -s http://127.0.0.1:8787/v1/chat/completions \
  -H 'content-type: application/json' \
  -H 'x-wardwright-agent-id: smoke-agent' \
  -d '{"model":"wardwright/coding-balanced","messages":[{"role":"user","content":"hello"}]}'
```

Run tests:

```bash
mise exec -- gleam format --check src
mise exec -- mix test
```

## Implemented Surface

- `GET /v1/models`
- `GET /v1/synthetic/models` returns public model summaries only.
- `POST /v1/chat/completions`
- `POST /v1/synthetic/simulate`
- `GET /v1/policy-authoring/tools`
- `GET /v1/policy-authoring/projections/{pattern}`
- `GET /v1/policy-authoring/simulations/{pattern}`
- `POST /v1/policy-authoring/validate`
- `POST /v1/policy-authoring/scenarios/{pattern}`
- `GET /v1/receipts`
- `GET /v1/receipts/{id}`
- `GET /admin/providers`
- `GET /admin/storage`
- `GET /admin/runtime`
- `GET /admin/synthetic-models`
- `GET /policies`

The public synthetic model is available as both `coding-balanced` and
`wardwright/coding-balanced`. Requests are routed by a simple prompt-length
estimate: prompts at or below 32,768 estimated tokens select
`local/qwen-coder`; larger prompts select `managed/kimi-k2.6`. Chat and
simulation calls write in-memory receipts and publish runtime visibility events
through Phoenix PubSub. Caller context is extracted from `X-Wardwright-*` and
`X-Client-Request-Id` headers first, then from request `metadata`.

Detailed synthetic-model records include route graphs, prompt transforms, and
governance policy internals; read them through `/admin/synthetic-models`.
Prototype-sensitive endpoints are restricted to loopback callers unless
`WARDWRIGHT_ADMIN_TOKEN` or `config :wardwright, :admin_token` is set and the
request provides `Authorization: Bearer <token>` or
`X-Wardwright-Admin-Token`. This currently covers `/admin/*`, receipt reads,
and policy-cache read/write APIs. This is intended for a homelab or
single-operator deployment shape. It is not a full multi-user auth system:
provider API keys should stay behind fnox-backed secret lookup, while decisions
about who may use a synthetic model, configure a provider, or enter through SSO
depend on the eventual deployment topology.

## BEAM Direction

Elixir is the active backend direction for this platform. BEAM processes map
well to request-scoped route planning, provider attempts, receipt writing, and
stream policy governors. Supervision trees make provider adapter lifecycles,
health workers, rate-limit state, and circuit breakers explicit instead of
incidental. Streaming is also a real advantage: Cowboy/Plug can chunk SSE
today, and a fuller implementation could use GenStage/Broadway or plain
process mailboxes to model backpressure between provider streams, policy
inspection, and client release. Phoenix LiveView now owns the first-party
policy projection workbench.

The tradeoff is packaging and ecosystem fit. Elixir releases are mature, but OTP
distribution, runtime tuning, and container image discipline become part of the
product. Provider SDK coverage is also less uniform than JavaScript or Python,
so this backend should prefer normalized HTTP adapters over vendor SDK
dependence.

Policy execution is split by trust tier. Local/operator-authored policy can use
structured primitives and Dune-backed BEAM snippets with timeout, reduction, and
memory caps. Externally shared or untrusted policy should target a stronger
portable boundary such as WASM, a sidecar, or a hosted policy service.

Current pure policy decisions use Gleam where the boundary is stable enough:
structured-output guard-loop status, recent-history threshold classification,
alert enqueue/backpressure classification, normalized action/result metadata,
and route-planner strategy/reason classification. Keep process ownership,
open config-map parsing, provider boundaries, and side-effecting delivery in
Elixir unless a later spike proves a better split.
Set `WARDWRIGHT_POLICY_CORE=elixir`, `gleam`, or `compare` to select the runtime
decision implementation; `compare` executes both implementations and raises on
semantic drift.

The old Go and Rust backend prototypes remain in git history as bakeoff
evidence, but they are no longer part of the live tree.
