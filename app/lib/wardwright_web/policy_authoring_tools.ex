defmodule WardwrightWeb.PolicyAuthoringTools do
  @moduledoc false

  def list do
    [
      tool(
        "explain_projection",
        "GET",
        "/v1/policy-authoring/projections/{pattern_id}",
        "Return the deterministic projection, including state machine, phase, effect, conflict, and opaque-region data."
      ),
      tool(
        "simulate_policy",
        "GET",
        "/v1/policy-authoring/simulations/{pattern_id}",
        "Return canned simulation evidence linked to projection node ids and the current artifact hash."
      ),
      tool(
        "propose_rule_change",
        "not_implemented",
        nil,
        "Future draft-only tool: propose deterministic artifact diffs without applying them."
      ),
      tool(
        "validate_policy_artifact",
        "POST",
        "/v1/policy-authoring/validate",
        "Validate the current or submitted policy artifact for structural errors, opaque regions, missing scenario coverage, and unsupported provider stream capabilities."
      )
    ]
  end

  defp tool(name, method, path, description) do
    %{
      "name" => name,
      "method" => method,
      "path" => path,
      "description" => description
    }
  end
end
