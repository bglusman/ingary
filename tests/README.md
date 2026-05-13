# Ingary Contract Tests

`contract_probe.py` is the first shared HTTP contract and fuzz probe for the
backend prototypes. It intentionally uses only the Python standard library so
it can run before we choose a backend language or codegen stack.

Run a backend on `127.0.0.1:8787`, then:

```bash
python3 tests/contract_probe.py \
  --base-url http://127.0.0.1:8787 \
  --fuzz-runs 50
```

The probe checks:

- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/synthetic/simulate`
- `GET /v1/receipts`
- `GET /v1/receipts/{receipt_id}`
- `GET /admin/providers`
- `GET /admin/synthetic-models`
- flat and `ingary/` model namespace variants
- caller metadata precedence and receipt provenance
- basic latency percentiles

This is a behavioral gate, not a full OpenAPI validator. Later phases should
add generated OpenAPI schema tests, streaming-specific tests, property tests for
route graph invariants, and load/backpressure tests.
