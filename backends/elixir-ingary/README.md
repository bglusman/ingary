# elixir-ingary

Minimal Elixir/Plug prototype for the Ingary synthetic model platform contract.
It serves mock responses only; no provider credentials or outbound model calls
are involved.

## Run

```bash
cd backends/elixir-ingary
mix deps.get
mix run --no-halt
```

The server binds to `127.0.0.1:8787` by default. Override with:

```bash
INGARY_BIND=127.0.0.1:8788 mix run --no-halt
```

Smoke check:

```bash
curl http://127.0.0.1:8787/v1/models

curl -s http://127.0.0.1:8787/v1/chat/completions \
  -H 'content-type: application/json' \
  -H 'x-ingary-agent-id: smoke-agent' \
  -d '{"model":"ingary/coding-balanced","messages":[{"role":"user","content":"hello"}]}'
```

Run tests:

```bash
mix test
```

## Implemented Surface

- `GET /v1/models`
- `GET /v1/synthetic/models`
- `POST /v1/chat/completions`
- `POST /v1/synthetic/simulate`
- `GET /v1/receipts`
- `GET /v1/receipts/{id}`
- `GET /admin/providers`
- `GET /admin/storage`
- `GET /admin/synthetic-models`

The public synthetic model is available as both `coding-balanced` and
`ingary/coding-balanced`. Requests are routed by a simple prompt-length
estimate: prompts at or below 32,768 estimated tokens select
`local/qwen-coder`; larger prompts select `managed/kimi-k2.6`. Chat and
simulation calls write in-memory receipts. Caller context is extracted from
`X-Ingary-*` and `X-Client-Request-Id` headers first, then from request
`metadata`.

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

The old Go and Rust backend prototypes remain in git history as bakeoff
evidence, but they are no longer part of the live tree.
