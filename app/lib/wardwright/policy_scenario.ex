defmodule Wardwright.PolicyScenario do
  @moduledoc false

  defstruct [
    :id,
    :pattern_id,
    :title,
    :source,
    :input_summary,
    :expected_behavior,
    :verdict,
    :trace,
    :receipt_preview,
    :pinned,
    :created_at,
    :updated_at
  ]

  def from_map(map, pattern_id) when is_map(map) and is_binary(pattern_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    scenario = %__MODULE__{
      id: string_field(map, "scenario_id") || string_field(map, "id"),
      pattern_id: pattern_id,
      title: string_field(map, "title"),
      source: string_field(map, "source") || "user",
      input_summary: string_field(map, "input_summary"),
      expected_behavior: string_field(map, "expected_behavior"),
      verdict: verdict(map),
      trace: list_field(map, "trace"),
      receipt_preview: map_field(map, "receipt_preview"),
      pinned: boolean_field(map, "pinned", false),
      created_at: string_field(map, "created_at") || now,
      updated_at: now
    }

    validate(scenario)
  end

  def from_map(_map, _pattern_id), do: {:error, "scenario must be a JSON object"}

  def to_map(%__MODULE__{} = scenario, artifact_hash \\ nil) do
    [
      {"simulation_schema", "wardwright.policy_simulation.v1"},
      {"scenario_id", scenario.id},
      {"title", scenario.title},
      {"source", scenario.source},
      {"scenario_source", "persisted"},
      {"pinned", scenario.pinned},
      {"input_summary", scenario.input_summary},
      {"expected_behavior", scenario.expected_behavior},
      {"verdict", scenario.verdict},
      {"trace", scenario.trace},
      {"receipt_preview", scenario.receipt_preview},
      {"created_at", scenario.created_at},
      {"updated_at", scenario.updated_at},
      {"artifact_hash", artifact_hash}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def trace_state_ids(%__MODULE__{trace: trace}) do
    trace
    |> Enum.map(&string_field(&1, "state_id"))
    |> Enum.reject(&is_nil/1)
  end

  defp validate(%__MODULE__{id: id}) when id in [nil, ""],
    do: {:error, "scenario_id is required"}

  defp validate(%__MODULE__{source: source})
       when source not in ["user", "assistant", "fixture", "live_replay", "imported"],
       do: {:error, "source must be one of user, assistant, fixture, live_replay, imported"}

  defp validate(%__MODULE__{title: title}) when title in [nil, ""],
    do: {:error, "title is required"}

  defp validate(%__MODULE__{input_summary: input_summary}) when input_summary in [nil, ""],
    do: {:error, "input_summary is required"}

  defp validate(%__MODULE__{expected_behavior: expected_behavior})
       when expected_behavior in [nil, ""],
       do: {:error, "expected_behavior is required"}

  defp validate(%__MODULE__{trace: []}), do: {:error, "trace must include at least one event"}

  defp validate(%__MODULE__{trace: trace} = scenario) do
    case Enum.find(trace, &(not valid_trace_event?(&1))) do
      nil -> {:ok, scenario}
      _event -> {:error, "each trace event must include id, node_id, label, and severity"}
    end
  end

  defp valid_trace_event?(event) when is_map(event) do
    Enum.all?(["id", "node_id", "label", "severity"], &(string_field(event, &1) not in [nil, ""]))
  end

  defp valid_trace_event?(_event), do: false

  defp verdict(map) do
    case string_field(map, "verdict") do
      value when value in ["passed", "failed", "inconclusive"] -> value
      _ -> "inconclusive"
    end
  end

  defp string_field(map, key) do
    case json_get(map, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp boolean_field(map, key, default) do
    case json_get(map, key) do
      value when is_boolean(value) -> value
      _ -> default
    end
  end

  defp list_field(map, key) do
    case json_get(map, key) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp map_field(map, key) do
    case json_get(map, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp json_get(map, key) when is_map(map), do: Map.get(map, key)
  defp json_get(_value, _key), do: nil
end
