# Ingary

Ingary is an experimental synthetic model platform extracted from Calciforge's
model-gateway work.

The core idea: clients call stable model names such as `coding-balanced` or
`ingary/coding-balanced`, while Ingary owns the route graph behind that name:
provider selection, context-window fit checks, fallback policy, stream
governance, caller traceability, and receipts explaining every decision.

This repository is intentionally prototype-heavy right now. The goal is to pick
a foundation using a shared HTTP contract and measurable behavior rather than
choosing a language from preference alone.

## Current Contents

- `contracts/openapi.yaml` - draft HTTP/OpenAI-compatible contract.
- `tests/contract_probe.py` - dependency-free cross-backend HTTP probe.
- `prototypes/backends/rust-ingary` - clean Rust backend prototype.
- `prototypes/backends/go-ingary` - clean Go backend prototype.
- `prototypes/backends/elixir-ingary` - clean Elixir backend prototype.
- `prototypes/backends/litellm-spike` - LiteLLM foundation/integration spike.
- `prototypes/backends/tensorzero-spike` - TensorZero foundation/integration spike.
- `prototypes/frontend/web` - Vite/React UI prototype.
- `docs/rfcs/ingary-extraction.md` - product and architecture draft.
- `docs/rfcs/ingary-presentation.html` - self-contained HTML presentation.

## Shared Contract Probe

Run a backend on `127.0.0.1:8787`, then:

```bash
python3 tests/contract_probe.py \
  --base-url http://127.0.0.1:8787 \
  --fuzz-runs 50
```

The probe checks the common OpenAI-compatible and Ingary-specific surface:

- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/synthetic/simulate`
- `GET /v1/receipts`
- `GET /v1/receipts/{receipt_id}`
- `GET /admin/providers`
- `GET /admin/synthetic-models`
- flat and `ingary/` model namespace variants
- caller provenance and receipt fields
- basic latency percentiles

## License

Apache-2.0.
