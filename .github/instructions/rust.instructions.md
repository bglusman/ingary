---
applyTo: "**/*.rs"
---

# Rust Review Notes

- Prefer typed structs/enums after protocol/config boundaries.
- Avoid detached `tokio::spawn` work without cancellation and error reporting.
- Do not place prompt text, credentials, or provider tokens in argv or logs.
- Receipt and policy logic should keep deterministic decisions explicit.
- Do not use `unwrap()` in request-path code unless the invariant is local and
  obvious.
