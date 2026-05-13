# Go Ingary Mock Backend

Minimal Go prototype for the synthetic model platform contract in
`../../contracts/openapi.yaml`. It uses only the Go standard library and keeps
state in memory.

## Run

```bash
cd backends/go-ingary
go run .
```

The server listens on `127.0.0.1:8787` by default. Override it with:

```bash
INGARY_ADDR=127.0.0.1:8788 go run .
```

## Smoke

```bash
curl http://127.0.0.1:8787/v1/models

curl -s http://127.0.0.1:8787/v1/chat/completions \
  -H 'content-type: application/json' \
  -H 'X-Ingary-Tenant-Id: demo-tenant' \
  -H 'X-Ingary-Agent-Id: demo-agent' \
  -d '{
    "model": "ingary/coding-balanced",
    "messages": [
      {"role": "user", "content": "Write a small router in Go."}
    ],
    "metadata": {
      "session_id": "demo-session",
      "tags": ["smoke"]
    }
  }'

curl http://127.0.0.1:8787/v1/receipts
```

Implemented endpoints:

- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/synthetic/simulate`
- `GET /v1/receipts`
- `GET /v1/receipts/{id}`
- `GET /admin/providers`
- `GET /admin/synthetic-models`

## Behavior

The only synthetic model is `coding-balanced`, accepted as either
`coding-balanced` or `ingary/coding-balanced`.

Dispatcher selection is mocked from estimated prompt length:

- `local/qwen-coder` for prompts at or below `32768` estimated tokens
- `managed/kimi-k2.6` above that threshold

Caller context is copied from `X-Ingary-*` headers when present. Matching
metadata fields are used as fallback, and receipts record the source of each
value.

## Go Fit Critique

Go is a strong fit for a smoke backend like this: `net/http` is enough for a
clear contract-first server, startup is fast, binaries are simple to ship, and
the concurrency model maps well to provider fanout and receipt writes.

The tradeoff is that rich platform contracts become verbose without generated
types or a framework. For this product, Go would benefit from OpenAPI codegen,
typed route graphs, and structured middleware early; otherwise security-critical
caller attribution and routing policy can drift into loosely typed maps.
