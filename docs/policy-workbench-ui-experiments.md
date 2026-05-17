---
layout: default
title: Policy Workbench UI Experiments
description: Design target and comparison criteria for Wardwright policy visualization and assistant spikes.
---

# Policy Workbench UI Experiments

Wardwright's policy workbench should explain how a synthetic model call will be
governed before the operator activates a policy, then show what happened after a
live or simulated call. The deterministic policy artifact remains the source of
truth. The UI renders projections, simulations, receipts, and assistant drafts
as review aids.

## User Questions

The first workbench should answer these questions quickly:

- Which synthetic model route graph is configured before policy runs?
- Which policy rules constrain, override, retry, block, or escalate that route?
- Does the policy behave differently for local, cloud, alloy, fallback, or
  partial-context routes?
- What path did a simulated or live request take through the graph?
- Which parts of that path are deterministic, opaque, AI-assisted, or
  invocation-only?
- What exact policy artifact would be activated if the operator accepts the
  assistant's suggestion?

## Surfaces

### Route And Policy Overlay

Render the route plan and policy plan together, not as separate mental models.
The route graph is the baseline: dispatcher, cascade, weighted alloy, partial
alloy, fallback, and provider targets. The policy overlay is a second layer that
marks:

- candidate filters from `restrict_routes`
- explicit `switch_model` and `reroute` actions
- fail-closed `block` actions
- route starvation when all candidates are removed
- model-specific differences in policy coverage or capability
- receipt links proving which constraints were applied

The UI should preserve the distinction between "this model is configured" and
"this model is currently allowed for this request." Users need both to debug
unexpected routing.

State machines can be a useful bridge between policy behavior and model
routing, but state should not be reduced to exactly one backend model. A state
may bind a route policy such as "force this concrete model", "use this
dispatcher", "use this alloy", or "constrain candidates to this provider set".
That lets a review state move to a slower local model, a broad-search state use
an alloy, and a normal state use the default dispatcher without inventing a
separate routing mental model. The UI should display this as an optional
state-to-route binding. A one-state policy simply means "use the active route
plan unless a rule constrains it."

The important distinction for users is:

- state controls policy context and allowed transitions
- route binding controls candidate or selected backend models for that state
- effects and receipts prove which route constraint actually applied

This avoids hiding alloys, fallback, and partial-context composition behind a
single "model per state" label while still letting model-switching policies feel
like normal state transitions.

### Simulation Trace

Simulation is evidence, not authority. Each simulation should show:

- input facts and generated/canned scenario source
- expected behavior
- actual trace events
- policy nodes touched
- route nodes touched
- rejections, retries, rewrites, and escalation invocations
- receipt preview and final verdict

If a path invokes an agent, the first MVP can only simulate that the invocation
would happen. The result of the agent's reasoning should be marked
`unresolved`, `mocked`, or `recorded_fixture` until live agent calls are wired.

### Policy Assistant

The policy assistant should be a bounded authoring and review agent, not a
hidden policy engine. It proposes deterministic artifact changes, explains
projections, and generates simulations for operator approval.

The assistant prompt should tell the model:

- the deterministic policy artifact is authoritative
- every proposed change must produce a reviewable artifact diff
- claims about behavior must be backed by simulation or receipt evidence
- opaque engine regions must be called out instead of hand-waved
- agent escalation is nondeterministic and must be represented as such

Initial assistant tools:

- `explain_projection(policy_id, focus)`
- `simulate_policy(policy_artifact, scenarios)`
- `propose_rule_change(policy_artifact, intent, constraints)`
- `inspect_receipt(receipt_id)`
- `inspect_route_plan(synthetic_model, request_facts)`
- `validate_policy_artifact(policy_artifact)`

The chat UI should keep assistant output adjacent to the projection and artifact
diff it references. A message that cannot be connected to a projection node,
receipt, simulation, or artifact diff should be treated as advisory text only.

## Agent Escalation

Some policies may need to escalate to an agent before human escalation or final
alerting. This is useful when deterministic rules identify a risky or ambiguous
situation but the right action depends on context that is hard to encode as a
simple predicate.

This should be modeled as a policy action:

```yaml
action:
  type: escalate_to_agent
  agent_id: policy-reviewer
  timeout_ms: 1500
  allowed_tools:
    - inspect_receipt
    - inspect_route_plan
    - validate_policy_artifact
  on_timeout: fail_closed
```

Open questions for implementation:

- whether the mid-call agent can call external models or only local models
- whether the agent can change the route or only recommend a deterministic
  action
- what evidence is required before the agent's decision is trusted
- how global and per-rule retry/failure caps interact with agent invocation
- which receipts distinguish deterministic decisions from agent decisions

The UI must show agent escalation as a distinct node class. It is not the same
as a deterministic rule, and it is not human review.

## Spike Comparison

Compare UI spikes on these dimensions:

- projection clarity: can an operator understand route plus policy interaction?
- simulation clarity: can the user see why a request landed on an action?
- assistant fit: does the chat panel stay grounded in artifacts and tools?
- graph ergonomics: can the layout handle branching route/policy paths without
  visual clutter?
- LiveView fit: does the implementation keep authoritative state server-side?
- dependency risk: does the graph or component library add maintenance burden?
- testability: do LiveView tests assert behavior and review text, not CSS trivia?

## Candidate Primitives

- Native LiveView/HEEx/SVG keeps state server-owned and has the smallest
  dependency footprint. It is likely enough for small deterministic policy
  graphs and first simulations.
- Cytoscape.js is a strong candidate if graphs become interactive, dense, or
  need pan/zoom/layout behavior; the server should still own the graph data.
- Mermaid is useful for readable generated diagrams and docs, but less useful
  for a review workbench that needs trace overlays and selection state.
- ContEx/ApexCharts-style charting is useful for aggregate metrics, latency,
  failure rates, and mutation/eval scores, not for the primary policy graph.
- LiveFlow is worth watching as a LiveView-native graph option, but should be
  treated as experimental until its API and maintenance story are clearer.

For the first product slice, prefer native LiveView plus a stable projection
schema. Add a client graph hook only when a specific workflow proves that pan,
zoom, auto-layout, or large-graph interaction is needed.

Recipe catalogs should be another backend-owned boundary. The workbench may
offer built-in, workspace, and community sources, but community recipes should
be treated as untrusted data until imported and reviewed. The default community
hub can live at `wardwright.dev/recipes`, with configuration allowing private or
enterprise catalogs to replace it. Catalog entries should point to deterministic
policy artifacts, projection demos, scenarios, and docs; selecting a remote
recipe must not execute arbitrary policy code.

## 2026-05-15 LiveView UI Spike Notes

Scope: `app/lib/wardwright_web` only. The spike focused on the running
`/policies/route-privacy/phase_map` workbench and did not change policy
semantics.

Observations:

- The LiveView was attaching the root layout twice, which rendered a complete
  HTML document inside the LiveView container. Chrome inspection showed the
  sidebar and workspace squeezed into one grid column instead of a full
  workbench shell.
- The schema badge and short confidence badges wrapped vertically when the
  containing panel collapsed. This made the authority/projection relationship
  harder to scan before reviewing policy nodes.
- Operators need a faster first read than the phase map alone provides. A
  top-level summary strip now surfaces artifact authority, policy-node count,
  simulation evidence, and review load before the detailed projection.

Screenshot evidence:

- Before: `/tmp/wardwright-policy-workbench-before.png`
- After layout fix and summary strip: `/tmp/wardwright-policy-workbench-final.png`

## Agent Framework Candidates

Alloy and Jido are the two relevant Elixir agent candidates currently visible.

Alloy is a narrow OTP agent engine: provider abstraction, tools, supervised
agent servers, streaming, middleware, and small dependency footprint. It fits a
bounded in-product policy assistant if Wardwright wants to own persistence,
prompting, authorization, and UI state.

Jido is a broader autonomous-agent framework and ecosystem: agents, actions,
signals, AI package, telemetry, and multi-agent workflows. It fits longer-lived
policy-review agents, escalation workflows, and operational automation if those
become product features.

The likely path is Alloy first for the interactive policy assistant and a later
Jido spike for agent escalation or multi-agent policy-review workflows.

## References

- [Alloy](https://alloylabs.dev/) for a narrow OTP agent engine with providers,
  tools, middleware, streaming, and supervised agents.
- [Jido](https://jido.run/) for a broader Elixir agent framework and ecosystem
  with actions, signals, AI packages, telemetry, and multi-agent workflows.
- [Cytoscape.js](https://js.cytoscape.org/) for interactive graph
  visualization when policy graphs outgrow native SVG.
- [ContEx](https://contex-charts.org/) for server-side Elixir charting that may
  help aggregate dashboard metrics rather than primary policy graphs.
