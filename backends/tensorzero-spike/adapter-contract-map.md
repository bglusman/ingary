# Ingary To TensorZero Adapter Map

This file sketches the smallest adapter needed to put TensorZero behind the
Ingary OpenAPI contract without forking TensorZero.

## Request Translation

Input:

```json
{
  "model": "ingary/coding-balanced",
  "messages": [
    { "role": "user", "content": "Review this patch." }
  ],
  "metadata": {
    "session_id": "example-session"
  }
}
```

Adapter steps:

1. Normalize `ingary/coding-balanced` to synthetic model `coding-balanced`.
2. Extract caller fields from trusted headers first, then body metadata.
3. Estimate prompt length from chat messages.
4. Select the smallest eligible context window:
   - `local/qwen-coder` when the estimate fits 32,768 tokens.
   - `managed/kimi-k2.6` when the estimate requires the larger context window.
5. Create an Ingary receipt before the downstream call.
6. Call TensorZero:

```json
{
  "model": "tensorzero::function_name::ingary_coding_balanced",
  "messages": [
    { "role": "user", "content": "Review this patch." }
  ],
  "tensorzero::variant_name": "local_qwen_coder",
  "tensorzero::tags": {
    "ingary.receipt_id": "example-receipt-id",
    "ingary.synthetic_model": "coding-balanced",
    "ingary.synthetic_version": "2026-05-13.a",
    "ingary.selected_model": "local/qwen-coder"
  }
}
```

## Response Translation

TensorZero response fields that should be copied into the Ingary receipt:

- inference ID
- episode ID, when supplied
- selected variant name
- usage and raw usage, when requested
- provider/model metadata from raw response where available
- response status and latency

Ingary response headers:

```text
X-Ingary-Receipt-Id: example-receipt-id
X-Ingary-Selected-Model: local/qwen-coder
```

## Required Ingary-Owned Endpoints

These do not map cleanly to TensorZero and should stay in the adapter/core:

- `GET /v1/models`
- `POST /v1/synthetic/simulate`
- `GET /v1/receipts`
- `GET /v1/receipts/{id}`
- `GET /admin/providers`
- `GET /admin/synthetic-models`
