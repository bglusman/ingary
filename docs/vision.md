---
layout: default
title: Wardwright Vision
description: The product vision and current architecture direction for Wardwright.
---

# Wardwright Vision

Wardwright is a synthetic model platform for agentic systems. A caller asks for a
stable model name, such as `coding-balanced` or `wardwright/json-extractor`; Wardwright
decides what that name means today, records why, and exposes the result through
an OpenAI-compatible interface.

<div class="notice">
  <strong>Current status:</strong> this is a product vision and implementation
  plan, not a finished release. The repo is intentionally using
  docs-driven development: write down the contract, build prototypes against
  it, test the contract, then choose the production foundation using evidence.
</div>

## Product Shape

In the finished product, Wardwright should let an operator define synthetic models
as shareable artifacts:

- public model name and namespace behavior
- provider and gateway routing options
- request preamble and postscript prompt transforms
- caller, agent, session, tenant, and run traceability
- stream governance and bounded buffering rules
- output validation and repair rules
- alert hooks for operator intervention
- receipt, log, and event-sink behavior

The key distinction is that the public model name is not just an alias for one
provider model. It is a governed contract.

## Requirements Direction

The first product audience is technical policy authors: people who can reason
about model/provider behavior, receipts, rules, and rollout risk, but who should
not need to be backend developers to author or review policy. Nontechnical
authoring help remains valuable, but it should be delivered through guided
assistant workflows, summaries, simulation, and visualization rather than by
weakening the underlying governance model.

Near-term product priority is correctness plus policy authoring quality. That
means Wardwright should optimize for:

- deterministic enforcement semantics across request, route, stream, and final
  output phases
- authoring workflows that make policy behavior predictable before activation
- simulation and generated counterexamples that reveal policy mistakes
- receipts and traces that explain why a request took a specific route or
  action
- explicit comparison of backend semantics when Go, Rust, and Elixir prototypes
  differ in meaningful ways

The first coherent policy set should cover:

- TTSR-style stream reactions and rewrites that can stop known-bad output before
  it is released
- recent-history count/comparison rules, including regex counts over recent
  requests, responses, tool calls, or receipt events
- dynamic model-switching and route-selection logic driven by policy state
- conflict and arbitration rules for actions that cannot safely run in parallel

Policy authoring should remain UI- and config-centered. Natural language,
assistant review, visual graphs, simulation, and deterministic YAML/TOML/JSON
artifacts are the primary workflow. Direct snippets are appropriate when they
map closely to a rule or runtime hook, but arbitrary programmable policy should
be evaluated as an advanced authoring mode, not assumed to be the default.

The major open product question is the primary policy authoring model. Wardwright
should run comparable spikes for structured policy primitives and code-first
Starlark policy. Both spikes must use the same realistic policy scenarios so
the decision is based on authoring clarity, simulation quality, review safety,
and debugging speed rather than raw expressiveness.

## Request Flow

<div class="flow">
  <div class="flow-step"><strong>1. Caller</strong> sends a normal OpenAI-style chat completion request.</div>
  <div class="flow-step"><strong>2. Wardwright</strong> resolves the synthetic model name and captures caller provenance.</div>
  <div class="flow-step"><strong>3. Policy</strong> can transform the prompt, pick a route, validate stream events, retry, alert, or stop.</div>
  <div class="flow-step"><strong>4. Provider</strong> receives only the concrete request Wardwright has chosen to send.</div>
  <div class="flow-step"><strong>5. Receipt</strong> records the route, policy actions, timing, usage, and final outcome.</div>
</div>

## Early Policy Demos

The strongest demonstrations are not generic chatbot filters. They are
constrained workflows with known failure modes:

- stop or reroute repeated tool loops before cost runs away
- detect ambiguous completion when an agent claims success without producing
  the expected artifact
- repair or reject malformed JSON, XML, or other structured output
- alert a human operator when uncertainty, retries, or spend cross a threshold
- add or vary request preambles and postscripts for controlled experiments
- record caller and consuming-agent visibility across shared synthetic models

Security policies still matter, especially around prompt injection and leakage,
but they are one family of governance examples rather than the product's whole
identity.

## Integration Strategy

Wardwright should work in two deployment shapes:

- **Wardwright as the caller entry point:** agents call Wardwright; Wardwright can use
  LiteLLM, Helicone, OpenRouter, Ollama, or direct provider adapters downstream.
- **Wardwright behind another gateway:** a gateway exposes `wardwright/*` model names;
  Wardwright owns those model definitions and calls concrete providers downstream.

The preferred public namespace is flat when Wardwright owns the whole model catalog
and prefixed, such as `wardwright/coding-balanced`, when Wardwright is one provider
inside a larger gateway.

## Implementation Direction

The repository initially kept Go, Rust, and Elixir backend prototypes alive so
they could be measured against the same contract. That comparison has now served
its purpose. The current implementation direction is **Elixir plus Gleam on the
BEAM**: Elixir owns supervision, process boundaries, HTTP, LiveView, provider
IO, telemetry, PubSub visibility, and dynamic runtime behavior; Gleam owns
correctness-heavy pure decision logic where typed data and exhaustive pattern
matching can prevent policy bugs. Session/model processes should publish
receipt, policy, queue, and simulation events over Phoenix PubSub so LiveView
and other cluster nodes can observe runtime behavior without directly mutating
another node's hot session state once a deployment has explicit node discovery
and clustering configured. The Go and Rust backends remain in git history as
evidence, but they are no longer carried in the live tree. Systems such as
LiteLLM, TensorZero, and Helicone remain useful integration targets and sources
of product ideas, but Wardwright should not begin life as a long-running fork of
any of them.

The first durable implementation should prioritize:

1. a small, clear OpenAI-compatible gateway surface
2. ETS-backed runtime state plus file-backed durable receipt storage and
   queryability, with Mnesia or SQL stores introduced when they buy concrete
   replication, query, concurrency, or deployment behavior
3. PubSub-backed visibility for LiveView and cluster projections, while
   authoritative session mutation remains owned by one runtime subtree
4. policy hooks for request, route, stream, and output phases
5. a policy-engine contract with explicit state scopes and two execution tiers:
   Dune-backed BEAM snippets for trusted local policy, and WASM/sidecar/hosted
   execution for externally shared or untrusted policy
6. a LiveView-first UI that exposes model definitions, live behavior, receipts,
   policy outcomes, simulations, and policy-shape explanations

See [Use Cases](use-cases.html) for the first policy examples that should drive
tests, docs, and UI workflows.
