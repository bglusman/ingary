# LiveView Native Policy Workbench Spike

This spike keeps the policy workbench mostly server-native: projection data is
assembled in `Wardwright.PolicyProjection`, rendered through HEEx components, and
the route graph overlay is plain SVG/CSS. No route planner or router core changes
were needed.

## What Is Real

- Route candidates are derived from `Wardwright.RoutePlanner.select/3` against
  the current synthetic model config.
- The workbench separates baseline route candidates from policy constraints:
  `restrict_routes`, `switch_model`, `reroute`, and fail-closed `block` through
  `route_blocked`.
- Receipt-facing fields are shown explicitly, including
  `policy_route_constraints.allowed_targets`,
  `policy_route_constraints.forced_model`, and `route_blocked`.
- Existing projection phases, effects, traces, conflicts, warnings, source spans,
  and runtime PubSub visibility stay on the page.

## What Is Mocked

- The assistant is a static chat panel. It defines the prompt/capability
  contract but does not call a model.
- Assistant tools are named but not wired:
  `explain_projection`, `simulate_policy`, `propose_rule_change`,
  `inspect_receipt`, `inspect_route_plan`, and `validate_policy_artifact`.
- Agent escalation is represented as a roadmap path with
  `agent_invocation_mock`. Simulation is invocation-only for now; the LiveView
  spike does not invoke an external agent.

## Design Tradeoffs

- The deterministic policy artifact remains the source of truth. The assistant
  can explain, simulate, and propose candidate changes, but activation still
  depends on a validated artifact.
- Keeping the graph native SVG avoids a heavy client-side graph dependency while
  still making selector, local model, managed model, policy removal, and
  fail-closed outcomes visible.
- Route overlay data lives in the projection layer rather than planner core so
  this remains a UI/projection spike. If later work needs exact planner internals
  such as every intermediate selector edge, that should become a stable backend
  projection contract rather than ad hoc LiveView logic.
