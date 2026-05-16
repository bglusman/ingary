---
layout: default
title: Packaging
description: Release, native binary, and Homebrew packaging plan for Wardwright.
---

# Packaging

Status: initial Burrito/Tinfoil packaging path in place. The next expected
publication is `v0.0.3`, a usable early release before the policy UI is
complete enough to call `0.1.0`.

Wardwright is a BEAM application with a Phoenix/LiveView operator UI and Gleam
decision cores. The packaging goal is a user-facing binary that does not require
Erlang, Elixir, or Gleam on the target machine.

## Chosen Path

Wardwright uses [Burrito](https://hexdocs.pm/burrito/readme.html) to wrap the
OTP release and ERTS into a self-extracting executable. Burrito is the best fit
for the first Wardwright package because it preserves normal BEAM supervision
and Phoenix runtime behavior while removing runtime language-tool dependencies.

[Tinfoil](https://hexdocs.pm/tinfoil/readme.html) sits around Burrito for release
automation. It builds per-platform archives, creates the GitHub Release, writes
checksums, and updates the existing `bglusman/homebrew-tap` tap with a generated
`wardwright` formula.

This is intentionally separate from source development. Developers should use
`mise run check` and `mise run run:app`; users should install published release
artifacts.

## Release Targets

The configured release matrix is:

- `aarch64-apple-darwin`
- `x86_64-apple-darwin`
- `x86_64-unknown-linux-musl`
- `aarch64-unknown-linux-musl`

The first Homebrew install path should focus on macOS. Linuxbrew support can
remain best-effort until there is a real user or staging host that needs it.

## Direct Linux Install

Tinfoil also publishes plain Linux tarballs to the GitHub Release. This should
be the default non-macOS distribution path before we have a reason to introduce
Docker.

The convenience installer supports Linux x86_64 and ARM64:

```bash
curl -fsSL https://raw.githubusercontent.com/bglusman/wardwright/main/scripts/install.sh | sh
```

For a pinned release:

```bash
curl -fsSL https://raw.githubusercontent.com/bglusman/wardwright/main/scripts/install.sh | sh -s -- --version v0.0.3
```

The script downloads the matching release archive, requires
`checksums-sha256.txt`, verifies the archive checksum, and installs `wardwright`
to `~/.local/bin` by default. A manual install is equivalent:

```bash
curl -fLO https://github.com/bglusman/wardwright/releases/download/v0.0.3/wardwright-0.0.3-x86_64-unknown-linux-musl.tar.gz
curl -fLO https://github.com/bglusman/wardwright/releases/download/v0.0.3/checksums-sha256.txt
sha256sum -c checksums-sha256.txt --ignore-missing
tar -xzf wardwright-0.0.3-x86_64-unknown-linux-musl.tar.gz
install -m 0755 wardwright ~/.local/bin/wardwright
```

The Linux binary has the same runtime contract as the Homebrew package: set a
stable `WARDWRIGHT_SECRET_KEY_BASE`, optionally set `WARDWRIGHT_ADMIN_TOKEN`,
and run the binary as the local HTTP service. Systemd packaging can be added
later without changing the release artifact shape.

## Local Planning

From `app/`:

```bash
mise exec -- mix tinfoil.plan
```

The plan should show a GitHub release for `bglusman/wardwright` and Homebrew tap
updates for `bglusman/homebrew-tap`.

To build locally on macOS, install Burrito's build prerequisites. Burrito
currently expects Zig 0.15.2. On macOS 26 / Xcode 26, use Homebrew's patched
`zig@0.15` formula rather than the upstream Zig archive:

```bash
brew install zig@0.15
WARDWRIGHT_SECRET_KEY_BASE="$(openssl rand -base64 64)" mise run package:build:darwin-arm64
```

Linux builds can use the upstream Zig 0.15.2 archive. Windows targets also need
`7z`, but Wardwright does not currently publish a Windows package.

The output binary lands in `app/burrito_out/`. Tinfoil's CI workflow wraps
per-target binaries into versioned release archives under `_tinfoil/`.

## Homebrew

The release workflow updates the existing tap:

```bash
brew tap bglusman/tap
brew install wardwright
brew services start wardwright
```

The generated formula:

- installs the Burrito-wrapped `wardwright` binary;
- creates `etc/wardwright`, `var/lib/wardwright`, and `var/log/wardwright`;
- generates `etc/wardwright/secret_key_base` on first install;
- runs Wardwright bound to `127.0.0.1:8787` under `brew services`;
- does not require Erlang, Elixir, or Gleam at runtime.

`WARDWRIGHT_ADMIN_TOKEN` remains optional for loopback-only use, but should be
set for any deployment exposed beyond local operator access.

## Release Workflow

The root workflow `.github/workflows/wardwright-release.yml` is adapted from
Tinfoil's generated workflow because this repository keeps the Mix app under
`app/`.

Tagging `v0.0.3` or later should:

1. Build Burrito binaries for each configured target.
2. Upload archives and checksums to a GitHub Release.
3. Publish provenance attestations.
4. Update `Formula/wardwright.rb` in `bglusman/homebrew-tap` for stable tags.

The Homebrew update job needs a `HOMEBREW_TAP_TOKEN` repository secret with
write access to `bglusman/homebrew-tap`. Tinfoil also supports deploy-key auth,
which is preferable once release automation is no longer experimental.

Dev tags such as `v0.1.0-dev` are published as GitHub prereleases but do not
update the Homebrew tap. The `0.1.0` milestone is reserved for the first release
where the policy UI and validation story are useful enough to promote.

## Known Gaps

- Release `v0.0.1` was cut, but its packaged payload missed the Gleam decision
  core modules and should be superseded by `v0.0.2`.
- Release `v0.0.2` is the first usable packaging baseline. `v0.0.3` is expected
  to add the initial policy visualization, simulation playback, and recipe
  catalog workbench boundary.
- The first CI run may expose platform-specific Burrito, Zig, or NIF issues.
  macOS builds intentionally install Homebrew `zig@0.15` because upstream Zig
  0.15.2 can fail to link on newer macOS/Xcode combinations.
- Burrito prints some wrapper diagnostics to stderr before the BEAM app starts.
- The current app has minimal static assets. If LiveView assets grow, packaging
  must add an explicit asset build/digest step before `mix release`.
- The formula is service-oriented and starts the HTTP app. A richer CLI can be
  added later without changing the package boundary.
