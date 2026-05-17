---
layout: default
title: Wardwright
description: Synthetic model contracts, governance, and receipts for agentic workflows.
---

<section class="hero">
  <p class="eyebrow">Synthetic model platform</p>
  <h1>Wardwright</h1>
  <p class="lede">
    Wardwright is a control plane for agent-facing model behavior. Agents call a
    stable model name; operators define the route graph, policy, caller
    traceability, prompt transforms, alert hooks, and receipts behind that name.
  </p>
  <div class="actions">
    <a class="button" href="#install">Install</a>
    <a class="button" href="vision.html">Read the Vision</a>
    <a class="button secondary" href="synthetic-models.html">Synthetic Models</a>
    <a class="button secondary" href="use-cases.html">Use Cases</a>
    <a class="button secondary" href="feature-spikes.html">Feature Spikes</a>
    <a class="button secondary" href="architecture-review-tasks.html">Architecture Tasks</a>
    <a class="button secondary" href="architecture-ratchets.html">Architecture Ratchets</a>
    <a class="button secondary" href="policy-workbench-implementation-plan.html">Workbench Plan</a>
    <a class="button secondary" href="tool-context-policy.html">Tool Policy</a>
    <a class="button secondary" href="packaging.html">Packaging</a>
    <a class="button secondary" href="https://github.com/bglusman/wardwright">GitHub</a>
  </div>
</section>

<div class="notice">
  <strong>Status:</strong> Wardwright is early but installable. Release
  <code>v0.0.3</code> publishes native macOS and Linux artifacts, a Homebrew
  formula, the active BEAM implementation, shared contracts, and tests used to
  validate policy behavior. See the
  [Backend Selection Decision](backend-selection-decision.html) for the pruning
  rationale.
</div>

## Install

Wardwright publishes native binaries through GitHub Releases and Homebrew.

### macOS Homebrew

```bash
brew tap bglusman/tap
brew install wardwright
brew services start wardwright
open http://127.0.0.1:8787/policies
```

### Linux

```bash
curl -fsSL https://raw.githubusercontent.com/bglusman/wardwright/main/scripts/install.sh | sh
WARDWRIGHT_SECRET_KEY_BASE="$(openssl rand -base64 64)" \
WARDWRIGHT_BIND=127.0.0.1:8787 \
~/.local/bin/wardwright
```

For a pinned release, pass `--version v0.0.3` to the installer:

```bash
curl -fsSL https://raw.githubusercontent.com/bglusman/wardwright/main/scripts/install.sh | sh -s -- --version v0.0.3
```

The Linux installer verifies the release archive against published SHA-256
checksums before installing. Set `WARDWRIGHT_ADMIN_TOKEN` before exposing
Wardwright beyond loopback. See [Packaging](packaging.html) for manual archive
install steps, release targets, and service details.

## What Wardwright Adds

LLM agents often fail in ways that are easy to miss: repeated tool loops,
partial success treated as completion, malformed structured output, runaway
context growth, unclear model/provider selection, and weak visibility into who
or what triggered a run.

Wardwright adds a narrow control point between agent code and concrete model
providers. It is not primarily a security product. Security policies are one
useful family of examples, but the larger goal is controlled experimentation
and runtime visibility for constrained agentic workflows.

<div class="grid">
  <div class="card">
    <h3>Synthetic Models</h3>
    <p>Stable public model IDs such as <code>coding-balanced</code> resolve to
    versioned route graphs and policy bundles.</p>
  </div>
  <div class="card">
    <h3>Governance</h3>
    <p>Built-in and programmable rules can transform requests, select routes,
    validate output, retry, alert, or later require explicit human approval.</p>
  </div>
  <div class="card">
    <h3>Receipts</h3>
    <p>Every run can produce a structured explanation of caller provenance,
    provider attempts, policy actions, costs, and final status.</p>
  </div>
  <div class="card">
    <h3>OpenAI-Compatible</h3>
    <p>Existing clients can call Wardwright through ordinary chat-completion APIs
    while Wardwright owns the behavior behind the model name.</p>
  </div>
</div>

## Current Focus

The active prototype started by comparing Go, Rust, and Elixir backends against
the same HTTP contract, storage contract, BDD scenarios, and property-style
probes. That comparison has served its purpose. The live codebase now keeps the
Elixir backend as the primary runtime, with Gleam used for correctness-heavy
pure business logic and LiveView for the operator UI. The old Go and Rust
backends remain available in git history, but they are no longer part of the
current tree or verification gate.

The current installable build includes the OpenAI-compatible gateway surface,
synthetic model routing, stream-policy retries/rewrites, tool-context policy
hooks, policy history/cache state, protected authoring APIs, receipts, and an
initial LiveView workbench for policy diagrams, simulation playback, recipe
selection, and tool-governance demos.

Near-term work:

1. Harden the policy workbench so projections and simulations are generated from
   persisted policy artifacts, compiled plans, and receipts.
2. Expand alert sinks and durable delivery/dead-letter semantics.
3. Add file-backed durable storage for model definitions and receipts, with
   Mnesia/SQL providers gated on concrete query, replication, or concurrency
   needs.
4. Broaden PubSub-backed visibility for model/session/receipt/policy events so
   LiveView and cluster nodes get near-real-time views without owning session
   state.
5. Use Dune-backed BEAM snippets for trusted local programmable policy only
   where structured primitives are insufficient.
6. Require WASM, a sidecar, or a hosted policy service for externally shared or
   otherwise untrusted programmable policy.

## Name

Wardwright is the tentative product name. The old working name, Ingary, was easy
to confuse and hard to remember. Code identifiers, protocol examples, and the
repository name now use `wardwright`; public project pages now use
`wardwright.dev`.
