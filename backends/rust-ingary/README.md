# rust-ingary

Minimal Rust backend prototype for the Ingary synthetic model platform contract.
It serves mock data only: no real provider calls, no persistence beyond process
memory, and no authentication.

## Run

```bash
cd backends/rust-ingary
cargo run
```

The server listens on `127.0.0.1:8787` by default. Override with:

```bash
INGARY_BIND=127.0.0.1:8790 cargo run
```

## Smoke

```bash
curl http://127.0.0.1:8787/v1/models
```

```bash
curl -s http://127.0.0.1:8787/v1/chat/completions \
  -H 'content-type: application/json' \
  -H 'X-Ingary-Agent-Id: smoke-agent' \
  -d '{
    "model": "ingary/coding-balanced",
    "messages": [{"role": "user", "content": "Write a small Rust function."}]
  }'
```

```bash
curl -s http://127.0.0.1:8787/v1/receipts
```

## Implemented Surface

- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/synthetic/simulate`
- `GET /v1/receipts`
- `GET /v1/receipts/{receipt_id}`
- `GET /admin/providers`
- `GET /admin/synthetic-models`

The public synthetic model is `coding-balanced`; requests may use either the
flat ID or `ingary/coding-balanced`. Route selection is deterministic:
estimated prompt tokens up to `32768` select `local/qwen-coder`; larger prompts
select `managed/kimi-k2.6`.

Caller fields are extracted from the `X-Ingary-*` headers, with request
`metadata` as a fallback. Header values win when both are present.

## Rust Fit Critique

Rust is a strong fit for the production shape of this product when routing,
policy evaluation, receipt integrity, and provider isolation matter. Axum,
Tokio, and Serde make the HTTP layer compact while keeping request and receipt
types explicit.

The tradeoff is iteration speed. A synthetic model platform will churn through
contract fields, admin workflows, and route graph experiments; Rust makes those
changes more deliberate than a dynamic backend would. That cost looks acceptable
for the security-sensitive control plane, but early product discovery may still
benefit from a faster scripting prototype beside this one.
