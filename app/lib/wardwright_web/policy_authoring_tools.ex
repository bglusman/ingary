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
        "Return persisted simulation scenarios when present, otherwise explicit fixture evidence linked to projection node ids and the current artifact hash."
      ),
      tool(
        "record_scenario",
        "POST",
        "/v1/policy-authoring/scenarios/{pattern_id}",
        "Persist a user, assistant, fixture, or live-replay scenario so simulations can use reviewed scenario records instead of demo fixtures."
      ),
      tool(
        "import_receipt_scenario",
        "POST",
        "/v1/policy-authoring/scenarios/{pattern_id}/from-receipt/{receipt_id}",
        "Import an existing receipt as a pinned live-replay scenario for later simulation evidence and regression export."
      ),
      tool(
        "export_regression_pack",
        "GET",
        "/v1/policy-authoring/scenarios/{pattern_id}/regression-export?format=json|exunit",
        "Export pinned scenario records as a deterministic regression pack or generated ExUnit source for native regression review."
      ),
      tool(
        "apply_scenario_retention",
        "POST",
        "/v1/policy-authoring/scenarios/{pattern_id}/retention",
        "Prune oldest unpinned scenario records for a policy pattern while always preserving pinned regression scenarios."
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

  def cli_descriptions do
    Enum.map(list(), fn tool ->
      path = tool["path"] || "not implemented"

      """
        #{tool["name"]}
          #{tool["method"]} #{path}
          #{tool["description"]}
      """
    end)
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
