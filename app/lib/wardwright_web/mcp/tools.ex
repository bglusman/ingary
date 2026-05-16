defmodule WardwrightWeb.MCP.Tools do
  @moduledoc false

  alias Hermes.MCP.Error
  alias Hermes.Server.Response

  def pattern_id(params) do
    Map.get(params, :pattern_id) || Map.get(params, "pattern_id")
  end

  def artifact(params) do
    Map.get(params, :artifact) || Map.get(params, "artifact") || %{}
  end

  def reply_json(payload, frame) when is_map(payload) do
    {:reply, Response.tool() |> Response.structured(payload), frame}
  end

  def execution_error(message, frame, data \\ %{}) do
    {:error, Error.execution(message, data), frame}
  end

  def known_pattern?(pattern_id) do
    pattern_id in Wardwright.PolicyProjection.pattern_ids()
  end
end
