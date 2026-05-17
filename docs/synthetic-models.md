---
layout: default
title: Synthetic Model Composition
description: Route selectors and model-composition primitives for Wardwright synthetic models.
---

# Synthetic Model Composition

Wardwright synthetic models are stable public model IDs backed by a route graph,
not aliases for one upstream provider. The first route primitives are inherited
from Calciforge's model gateway work and are deliberately small:

- **dispatcher**: choose the smallest eligible context window for the request,
  while keeping larger eligible targets as fallback attempts
- **cascade**: try configured models in declaration order, skipping targets
  whose context windows cannot fit the request
- **alloy**: blend equivalent constituents through deterministic-all, weighted,
  or round-robin-style selection

Two outside ideas define the shape of this work. XBOW's "model alloy" writeups
show that alternating multiple LLMs inside one agent context can outperform a
single-model monoculture on agentic search tasks. oh-my-pi's Time Traveling
Streamed Rules show that rules can sit outside the prompt until model output
actually triggers them, then abort and retry with a targeted reminder.

References:

- [XBOW: Agents Built From Alloys](https://xbow.com/blog/alloy-agents/)
- [oh-my-pi Time Traveling Streamed Rules](https://github.com/can1357/oh-my-pi#-time-traveling-streamed-rules-ttsr)

## Composition DAG Status

Today, dispatchers, cascades, and alloys compose concrete upstream targets.
That is enough for local-first gates, fallback chains, weighted/round-robin
selection, and partial-context alloys where a smaller local model drops out
after its context window is exceeded.

Wardwright does not yet resolve one synthetic model through another synthetic
model. The intended extension is a selector DAG:

- selector references may point at concrete targets or other selectors
- cycles fail validation before serving
- expansion depth is capped and recorded in receipts
- receipts show the full route lineage, including skipped nested selectors
- the workbench can render the route graph separately from policy overlays

This would let a public synthetic model use a dispatcher whose large-context
branch is itself a cascade, or an alloy whose constituents are local and managed
synthetic models, while keeping loops impossible by construction.

## Dispatcher

Dispatchers are for request-shape routing. The current implementation uses
estimated prompt tokens and declared context windows. A small request can use a
local model; a larger request promotes to a bigger-context model without the
caller changing the public model name.

```json
{
  "route_root": "fit-dispatcher",
  "targets": [
    {"model": "local/qwen", "context_window": 32768},
    {"model": "managed/kimi", "context_window": 262144}
  ],
  "dispatchers": [
    {
      "id": "fit-dispatcher",
      "models": ["local/qwen", "managed/kimi"]
    }
  ]
}
```

Expected behavior:

- prompt estimate below `32768`: select `local/qwen`, keep `managed/kimi` as
  fallback
- prompt estimate above `32768` and below `262144`: select `managed/kimi`, record
  that `local/qwen` was skipped for context fit

## Policy Control

The route graph is the baseline model definition. Route policy runs before
provider selection and can narrow or override that baseline:

- `restrict_routes` adds an `allowed_targets` constraint. Entries may be concrete
  model IDs such as `local/qwen` or provider prefixes such as `local`.
- `switch_model` and `reroute` add a `forced_model` constraint.
- receipts include both the base route decision and `policy_route_constraints`,
  so the UI can show "what the model definition allowed" separately from "what
  policy removed or forced for this request."
- if policy removes every provider candidate, Wardwright fails closed and records
  `route_blocked` in the receipt instead of falling through to an arbitrary
  provider.

Built-in declarative route gates and Dune-backed policy snippets can both emit
these actions. WASM remains fail-closed until the runtime is enabled.

## Cascade

Cascades are reliability plans. They preserve declaration order and skip
impossible targets before a provider attempt is made.

```json
{
  "route_root": "local-then-remote",
  "cascades": [
    {
      "id": "local-then-remote",
      "models": ["local/qwen", "managed/kimi", "managed/reserve"]
    }
  ]
}
```

Expected behavior:

- try the first configured model that can fit the prompt
- keep later eligible models as fallback attempts
- never send an obviously oversized request to a smaller context window

## Alloy

Alloys are for composition when constituents are useful as one synthetic
behavior. Wardwright supports ordinary compatible-window alloys and a deliberate
partial-context mode for the user-facing "local plus long-context" use case.

```json
{
  "route_root": "local-kimi-partial",
  "alloys": [
    {
      "id": "local-kimi-partial",
      "strategy": "deterministic_all",
      "partial_context": true,
      "constituents": ["local/qwen", "managed/kimi"]
    }
  ]
}
```

Expected behavior:

- when the prompt fits both constituents, both participate
- when the prompt outgrows the smaller context window, the smaller constituent is
  skipped and the larger one continues alone
- receipts expose selected models, skipped targets, fallback models, route type,
  strategy, and the context-window reason

Weighted alloys model stochastic composition while keeping test runs
reproducible inside the pure route planner. Caller-supplied request metadata must
not control provider selection in the serving path.
