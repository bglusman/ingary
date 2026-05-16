defmodule WardwrightWeb.MCP.Tools.ValidatePolicyArtifact do
  @moduledoc """
  Validate a submitted policy artifact or the current configured artifact.
  """

  use Hermes.Server.Component, type: :tool, annotations: %{read_only: true}

  alias WardwrightWeb.MCP.Tools
  alias WardwrightWeb.PolicyArtifactValidator

  schema do
    field(:artifact, :map,
      description: "Optional policy artifact object. Omit to validate current config."
    )
  end

  @impl true
  def execute(params, frame) do
    artifact = Tools.artifact(params)
    source = if artifact == %{}, do: "current_config", else: "submitted"

    artifact
    |> PolicyArtifactValidator.validate(source: source)
    |> Tools.reply_json(frame)
  end
end
