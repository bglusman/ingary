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

## Elixir Fit Critique

Elixir is a strong fit for this platform's runtime shape. BEAM processes map
well to request-scoped route planning, provider attempts, receipt writing, and
stream policy governors. Supervision trees make provider adapter lifecycles,
health workers, rate-limit state, and circuit breakers explicit instead of
incidental. Streaming is also a real advantage: Cowboy/Plug can chunk SSE
today, and a fuller implementation could use GenStage/Broadway or plain
process mailboxes to model backpressure between provider streams, policy
inspection, and client release.

The tradeoff is packaging and ecosystem fit. Rust or Go produce simpler static
binaries for edge nodes and self-hosted operators who want one artifact. Elixir
releases are mature, but OTP distribution, runtime tuning, and container image
discipline become part of the product. Provider SDK coverage is also less
uniform than JavaScript, Python, Go, or Rust, so a serious Elixir backend should
prefer normalized HTTP adapters over vendor SDK dependence.

Policy VM choices should stay open. Elixir can embed policy as native modules,
run external WASM through a NIF/port boundary, call out to OPA/Rego, evaluate
CEL through a service or port, or host a small DSL compiled to Erlang terms.
Starlark is one option only if its operational and sandboxing story wins; the
platform should not assume it as the policy substrate.

Recommendation: Elixir is worth a serious backend spike for stream governance,
receipts, and adapter supervision. It is less compelling if the primary product
constraint is a tiny single-binary install footprint.
