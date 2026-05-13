# AGENTS.md — Ingary

Workspace-wide instructions for AI coding agents operating on this public repo.

## What This Repo Is

Ingary is an experimental synthetic model platform extracted from Calciforge's
model-gateway work. Clients call stable OpenAI-compatible model names while
Ingary owns route graphs, policy/governance, provider selection, caller
traceability, simulation, and receipts.

The repo intentionally contains multiple prototypes while we decide on a
foundation:

- `backends/go-ingary`
- `backends/rust-ingary`
- `backends/elixir-ingary`
- `frontend/web`
- `contracts`
- `tests`
- `docs`

## Public Repo Rules

Read `CLAUDE.md` before committing. It contains the public-repo secret
discipline rules, never-commit list, and gitleaks workflow. Those rules apply
to every agent, not only Claude.

In short:

- Do not commit secrets, bearer tokens, API keys, private endpoints, real
  deployment identifiers, real private model names, or private user/chat IDs.
- Use `.example` files and RFC-reserved placeholders.
- Do not bypass gitleaks or pre-commit checks.
- Do not put prompt text, credentials, or provider tokens in command argv.
- Do not log provider credentials or raw user content by default.

## Project Vocabulary

- **Ingary** — the product/repo.
- **Synthetic model** — stable public model contract backed by a route graph.
- **Route graph** — dispatcher/cascade/alloy/guard/concrete model graph.
- **Receipt** — structured record explaining route decisions, policy actions,
  provider attempts, caller provenance, and final status.
- **Governor / policy engine** — bounded decision layer for request transforms,
  routing, stream/output governance, alerts, retries, and receipt annotations.
- **Caller provenance** — tenant/application/agent/user/session/run metadata.

## Build / Test

```bash
# Go prototype
(cd backends/go-ingary && go test ./...)

# Rust prototype
(cd backends/rust-ingary && cargo fmt --check && cargo test)

# Elixir prototype
(cd backends/elixir-ingary && mix format --check-formatted && mix test)

# Frontend
(cd frontend/web && npm ci && npm run build)

# Shared Python contracts
python3 -m py_compile tests/*.py
python3 tests/storage_contract.py --store all --cases 50
```

When backend servers are running, shared HTTP probes should pass against all
active prototypes:

```bash
python3 tests/contract_probe.py --base-url http://127.0.0.1:8787 --fuzz-runs 10
python3 tests/contract_probe.py --base-url http://127.0.0.1:8797 --fuzz-runs 10
python3 tests/contract_probe.py --base-url http://127.0.0.1:8791 --fuzz-runs 10
```

## Product Contract Rules

- Keep the OpenAI-compatible serving surface stable unless the contract changes
  intentionally in `contracts/openapi.yaml`.
- Keep receipt summary shape consistent across all backends. In particular,
  `/v1/receipts` rows must include nested `caller` provenance.
- Keep generated/dynamic model tests portable across Go, Rust, and Elixir.
- Treat storage as a product contract, not an implementation detail. Update
  `contracts/storage-provider-contract.md` when changing durable behavior.
- Treat policy language as an engine choice behind a shared ABI. Starlark is the
  first intended portable advanced language; built-in declarative governors
  should cover common cases first.
- UI must distinguish live backend state from mock/not-implemented state.

## Git

- Prefer feature branches and PRs once branch protection is enabled.
- Do not push directly to `main` except for initial bootstrap/admin work before
  protections exist.
- Run `bash scripts/install-git-hooks.sh` in new clones.
