# Copilot Review Instructions For Ingary

Review conservatively. If uncertain, do not comment. Prefer one precise finding
over several speculative ones.

## Product Context

Ingary is a synthetic model platform. Clients call stable model names while
Ingary owns route graphs, policy/governance, provider selection, caller
traceability, simulation, and receipts.

## Highest-Value Review Areas

1. **Contract drift**
   - Backend responses must match `contracts/openapi.yaml`.
   - Receipt summaries must include nested `caller` provenance.
   - Go/Rust/Elixir prototype behavior should remain comparable where the
     shared contract says it is comparable.

2. **Policy/governance correctness**
   - Policy decisions must be deterministic and bounded.
   - Prompt transforms must be recorded in receipts.
   - Output governance must not release blocked buffered content.

3. **Secret/data leakage**
   - Do not log provider credentials, bearer tokens, or raw prompts by default.
   - Do not persist prompts/completions unless content capture is explicit.
   - Do not add private endpoints, real model names from a private deployment,
     or real user data.

4. **Live vs mock honesty**
   - UI must not silently substitute mock data for failed live endpoints.
   - Mock, simulated, unsupported, and real provider attempts should be clear in
     receipts and UI.

5. **Storage behavior**
   - Storage changes should satisfy `contracts/storage-provider-contract.md`.
   - Durable receipt metadata should keep indexed structured dimensions, not
     rely only on opaque JSON scans.

## Avoid Noise

- Do not ask for broad rewrites.
- Do not comment on formatting; CI handles it.
- Do not ask for generic "more tests" without naming the specific assertion.
- Do not flag example placeholders such as `example.com`, loopback hosts, or
  RFC documentation IP ranges.
