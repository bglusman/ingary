---
layout: default
title: Ingary
description: Synthetic model contracts, governance, and receipts for agentic workflows.
---

<section class="hero">
  <p class="eyebrow">Synthetic model platform</p>
  <h1>Ingary</h1>
  <p class="lede">
    Ingary is a control plane for agent-facing model behavior. Agents call a
    stable model name; operators define the route graph, policy, caller
    traceability, prompt transforms, alert hooks, and receipts behind that name.
  </p>
  <div class="actions">
    <a class="button" href="vision.html">Read the Vision</a>
    <a class="button secondary" href="use-cases.html">Use Cases</a>
    <a class="button secondary" href="https://github.com/bglusman/ingary">GitHub</a>
  </div>
</section>

<div class="notice">
  <strong>Status:</strong> Ingary is early and docs-driven. This site describes
  the product shape we are building toward, while the repository contains
  working prototypes, shared contracts, and tests used to choose the first
  production foundation.
</div>

## What Ingary Adds

LLM agents often fail in ways that are easy to miss: repeated tool loops,
partial success treated as completion, malformed structured output, runaway
context growth, unclear model/provider selection, and weak visibility into who
or what triggered a run.

Ingary adds a narrow control point between agent code and concrete model
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
    validate output, retry, alert, or hand off to a human.</p>
  </div>
  <div class="card">
    <h3>Receipts</h3>
    <p>Every run can produce a structured explanation of caller provenance,
    provider attempts, policy actions, costs, and final status.</p>
  </div>
  <div class="card">
    <h3>OpenAI-Compatible</h3>
    <p>Existing clients can call Ingary through ordinary chat-completion APIs
    while Ingary owns the behavior behind the model name.</p>
  </div>
</div>

## Current Focus

The active prototype compares Go, Rust, and Elixir backends against the same
HTTP contract, storage contract, BDD scenarios, and property-style probes.
Fork-based foundation spikes have been removed from the codebase; the current
direction is to integrate with systems such as LiteLLM and TensorZero where
useful, while keeping Ingary's synthetic-model semantics independent.

Near-term work:

1. Implement real built-in governors for request, route, stream, and output phases.
2. Add alert sinks and policy receipt events.
3. Add durable SQLite storage for model definitions and receipts.
4. Add Starlark as the first portable advanced policy language.
5. Keep WASM and external policy engines as later pluggable execution targets.

## Name

Ingary is a small literary nod to the country in Diana Wynne Jones's
<cite>Howl's Moving Castle</cite>. Calciforge began with Calcifer-adjacent
language, and Ingary keeps that origin visible while giving this project its
own cleaner identity. There is no affiliation with the book, film, author, or
studio.
