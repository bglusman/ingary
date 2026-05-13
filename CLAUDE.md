# CLAUDE.md — Instructions for Claude Code and Other Agents

This repository is public. Anything committed here can be read by anyone,
including git history. Plan accordingly.

## Never Commit These

- API tokens, passwords, session keys, bearer tokens, or provider credentials.
- Deployment-specific infrastructure identifiers:
  - personal domains and subdomains
  - dynamic-DNS hostnames
  - private LAN IP addresses
  - real chat/user IDs tied to specific people
  - private model names that exist only in a maintainer deployment
- Vault or credential-store URLs pointing at specific instances.
- Hard-coded fallback URLs that disclose infrastructure if an environment
  variable is unset.
- Real captured prompts/completions from users unless explicitly scrubbed and
  packaged as safe eval fixtures.

## Use These Instead

- Env vars with no production-identifying default.
- RFC-reserved examples such as `https://example.com`, `192.0.2.1`,
  `198.51.100.10`, or `203.0.113.10`.
- `*.example.*` files for copy-and-edit configs.
- Synthetic fixtures under `tests/**/fixtures/`.

## Two-Layer Gitleaks Setup

- `.gitleaks.toml` is public and generic. It catches common secret and
  infrastructure-disclosure shapes and runs in CI.
- `.gitleaks.local.toml` is gitignored and local-only. Copy
  `.gitleaks.local.toml.example` and add maintainer/deployment-specific
  domains, handles, private hostnames, and other identifiers there.

Run before committing:

```bash
gitleaks protect --staged --config .gitleaks.toml --verbose
```

Optionally also run:

```bash
gitleaks protect --staged --config .gitleaks.local.toml --verbose
```

Do not bypass gitleaks with `--no-verify`. CI will still run the public scan.

## Repo-Specific Cautions

- Receipts must not include prompts/completions by default.
- Logs must not include provider credentials or bearer headers.
- Optional Ollama/local provider tests are acceptable, but do not commit local
  hostnames, private model names, or personal endpoints.
- Policy examples should be inspectable and safe. Opaque/hosted policy is a
  future product path, not a reason to commit proprietary or private policy code.
