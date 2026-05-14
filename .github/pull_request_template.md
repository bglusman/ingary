## Description

Briefly describe the change and why it matters.

## Testing

- [ ] Go: `cd backends/go-ingary && go test -count=1 ./...`
- [ ] Rust: `cd backends/rust-ingary && cargo fmt --check && cargo test`
- [ ] Elixir: `cd backends/elixir-ingary && mix format --check-formatted && mix test`
- [ ] Frontend: `cd frontend/web && npm run build`
- [ ] Contracts: `python3 -m py_compile tests/*.py`
- [ ] Storage contract: `python3 tests/storage_contract.py --store all --cases 50`

## Contract Impact

- [ ] No API/receipt/storage contract change
- [ ] Updated `contracts/openapi.yaml`
- [ ] Updated `contracts/storage-provider-contract.md`
- [ ] Updated shared probes/tests

## Secret Discipline

- [ ] No secrets, private endpoints, private model names, or real user data added
- [ ] Example values use RFC/example placeholders

## Notes

Add screenshots, receipts, or relevant local output if useful.
