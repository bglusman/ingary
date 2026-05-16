defmodule WardwrightWeb.MCPServer do
  @moduledoc false

  use Hermes.Server,
    name: "wardwright-policy-authoring",
    version: "0.1.0",
    capabilities: [:tools]

  component(WardwrightWeb.MCP.Tools.ExplainProjection, name: "explain_projection")
  component(WardwrightWeb.MCP.Tools.SimulatePolicy, name: "simulate_policy")
  component(WardwrightWeb.MCP.Tools.ValidatePolicyArtifact, name: "validate_policy_artifact")
end
