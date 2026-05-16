defmodule WardwrightWeb.MCPServer do
  @moduledoc false

  use Hermes.Server,
    name: "wardwright-policy-authoring",
    version: Mix.Project.config()[:version],
    capabilities: [:tools]

  component(WardwrightWeb.MCP.Tools.ExplainProjection, name: "explain_projection")
  component(WardwrightWeb.MCP.Tools.SimulatePolicy, name: "simulate_policy")
  component(WardwrightWeb.MCP.Tools.ValidatePolicyArtifact, name: "validate_policy_artifact")
end
