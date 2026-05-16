defmodule WardwrightWeb.MCP.Tools.SimulatePolicy do
  @moduledoc """
  Return persisted or fixture-backed simulation evidence for one policy pattern.
  """

  use Hermes.Server.Component, type: :tool, annotations: %{read_only: true}

  alias WardwrightWeb.MCP.Tools

  schema do
    field(:pattern_id, :string, required: true, description: "Policy pattern id to simulate.")
  end

  @impl true
  def execute(params, frame) do
    pattern_id = Tools.pattern_id(params)

    if Tools.known_pattern?(pattern_id) do
      Tools.reply_json(%{"data" => Wardwright.PolicyProjection.simulations(pattern_id)}, frame)
    else
      Tools.execution_error("policy pattern not found", frame, %{pattern_id: pattern_id})
    end
  end
end
