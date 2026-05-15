## Description

Briefly describe the change and why it matters.

## Testing

- [ ] App: `cd app && mise exec -- mix format --check-formatted && mise exec -- mix test`
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
