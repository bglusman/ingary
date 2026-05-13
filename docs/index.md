---
layout: default
title: Ingary
description: Synthetic model contracts, governance, and receipts for agentic workflows.
---

<section class="hero">
  <p class="eyebrow">Synthetic model platform</p>
  <h1>Ingary</h1>
  <p class="lede">
    Ingary lets agents call stable model names while operators own the route
    graph, governance policy, provider choices, caller traceability, and
    receipts behind those names.
  </p>
  <div class="actions">
    <a class="button" href="https://github.com/bglusman/ingary">GitHub</a>
    <a class="button secondary" href="rfcs/ingary-presentation.html">Design Presentation</a>
  </div>
</section>

## Why It Exists

LLM agents are useful, but production workflows often fail in ways that are
hard to see and harder to constrain: repeated tool loops, partial success
treated as completion, malformed structured output, runaway context growth,
and unclear model/provider choices.

Ingary adds a control point between agent code and concrete model providers.
It is not primarily a security product. Security policies are one useful
example, but the broader goal is predictable experimentation and visibility for
constrained agentic workflows.

## Core Concepts

<div class="grid">
  <div class="card">
    <h3>Synthetic Models</h3>
    <p>Stable public model IDs such as <code>coding-balanced</code> that resolve
    to versioned route graphs.</p>
  </div>
  <div class="card">
    <h3>Governance</h3>
    <p>Built-in and programmable policies for request transforms, routing,
    output validation, retries, alerts, and human handoff.</p>
  </div>
  <div class="card">
    <h3>Receipts</h3>
    <p>Structured explanations of caller provenance, route decisions, provider
    attempts, policy actions, and final status.</p>
  </div>
  <div class="card">
    <h3>OpenAI-Compatible</h3>
    <p>Agents can use ordinary chat-completion clients while Ingary owns the
    behavior behind the model name.</p>
  </div>
</div>

## Early Policy Demonstrations

Ingary's strongest early demos are constrained workflows with known failure
modes:

- loop and tool-spam detection
- structured JSON/XML output repair
- ambiguous-success detection
- cost and context budget governors
- prompt preamble/postscript experiments
- human alert hooks when a run crosses risk thresholds
- prompt-injection and leakage guards as one policy family, not the whole
  product identity

## Current Prototype

The repository currently contains Go, Rust, and Elixir backend prototypes, a
React control-plane prototype, shared OpenAPI/storage contracts, and executable
contract/property tests.

```bash
python3 tests/contract_probe.py --base-url http://127.0.0.1:8787 --fuzz-runs 10
python3 tests/storage_contract.py --store all --cases 50
```

## Roadmap

Near-term work:

1. Implement real built-in governors for request/input, route, and output phases.
2. Add alert sinks and policy receipt events.
3. Add durable SQLite storage for model definitions and receipts.
4. Add Starlark as the first portable advanced policy language.
5. Keep WASM and external sidecar engines as later pluggable execution targets.

See the [design presentation](rfcs/ingary-presentation.html) and the repository
RFCs for the current architecture draft.
