# UI Spike B: LiveView Hook Graph Workbench

## Scope

This spike keeps the deterministic policy artifact as the source of truth and
uses projection and simulation output as explanatory evidence. The UI adds a
route graph workbench, model-by-model policy overlay table, mocked policy
assistant contract, and a separate mocked governance escalation action.

## Graph Primitive Choice

Chosen primitive: a minimal custom client-side SVG renderer in
`app/priv/static/assets/policy_workbench.js`.

Phoenix serves it through `WardwrightWeb.Endpoint` because `Plug.Static` exposes
the `assets` directory from `:wardwright` priv static at `/assets/*`. The layout
loads it with:

```html
<script defer src="/assets/policy_workbench.js"></script>
```

The LiveView emits a server-rendered fallback graph plus JSON in
`data-route-graph`. The script enhances that markup into an interactive SVG and
updates the inspector when a route node is selected.

Tradeoffs considered:

- Cytoscape.js: best fit for large interactive graphs, but too much dependency
  surface for the current two-to-five-node route graph.
- D3: flexible and durable, but it would add a general visualization toolkit
  before the projection contract needs that power.
- Mermaid: small authoring surface for static diagrams, but weak for receipt
  overlays and click-driven inspection.
- ApexCharts/Flowbite-style dashboards: useful for operational metrics, not for
  explaining route topology and policy constraints.
- LiveFlow: interesting if the UI becomes a live process/flow diagram, but not
  needed for this graph spike.
- Minimal custom hook: enough for route graph topology, baseline candidates,
  policy overlay state, and node inspection without changing Mix deps.

## Assistant Contract

The assistant panel is mocked/static. Its contract is deliberately narrow:

- `explain_projection`
- `simulate_policy`
- `propose_rule_change`
- `inspect_receipt`
- `inspect_route_plan`
- `validate_policy_artifact`

The assistant may explain, simulate, inspect, and draft proposals. It must not
activate behavior from simulation output. Any proposal must be validated against
the deterministic policy artifact before activation.

## Governance Escalation

Agent escalation is represented as `kind: agent_escalation` with
`activation: simulation_invocation_only`. It is visually separated from
deterministic route actions such as `restrict_routes`, `switch_model`,
`reroute`, and `block`.

## Elixir Agent Framework Notes

Verified package names on 2026-05-15:

- Alloy exists on Hex as `alloy`; its package description is "Model-agnostic
  agent harness for Elixir" and the current package metadata points to the
  `alloy-ex/alloy` GitHub project. Source: <https://hex.pm/packages/alloy>.
- Jido exists on Hex as `jido`; its package description is "An autonomous agent
  framework for Elixir, built for workflows and multi-agent systems." Source:
  <https://hex.pm/packages/jido>.
- `jido_ai` exists as the AI/LLM extension path for Jido. Source:
  <https://hexdocs.pm/jido_ai/getting_started.html>.
- `judo` did not resolve through the Hex package API during this spike
  (`https://hex.pm/api/packages/judo` returned 404).
- `juno` exists on Hex, but current package metadata describes it as flexible
  JSON decoding for Gleam, not an Elixir AI agent framework. Source:
  <https://hex.pm/packages/juno>.

Fit for this surface:

- For the near-term mocked assistant panel, Alloy looks like the better match:
  a small request/response agent harness with tool calls maps closely to
  "explain this projection, inspect this receipt, propose a draft change."
- Jido/Jido AI looks stronger if Wardwright wants long-running supervised
  policy-review agents, multi-agent workflows, durable signal routing, or
  governance processes that live naturally under OTP supervision.

No Elixir dependency was added in this spike.
