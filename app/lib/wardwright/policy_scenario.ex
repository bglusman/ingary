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

  def from_receipt(receipt, pattern_id, attrs \\ %{})
      when is_map(receipt) and is_binary(pattern_id) and is_map(attrs) do
    receipt_id = string_field(receipt, "receipt_id")

    if receipt_id in [nil, ""] do
      {:error, "receipt_id is required"}
    else
      receipt
      |> receipt_attrs(pattern_id, attrs, receipt_id)
      |> from_map(pattern_id)
    end
  end

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
      {"pattern_id", scenario.pattern_id},
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

  defp receipt_attrs(receipt, pattern_id, attrs, receipt_id) do
    final = map_field(receipt, "final")
    stream_policy = map_field(final, "stream_policy")
    status = string_field(final, "status") || string_field(stream_policy, "status") || "unknown"

    Map.new([
      {"scenario_id", string_field(attrs, "scenario_id") || "receipt-#{receipt_id}"},
      {"title", string_field(attrs, "title") || "Receipt #{receipt_id}"},
      {"source", "live_replay"},
      {"pinned", boolean_field(attrs, "pinned", true)},
      {"input_summary", string_field(attrs, "input_summary") || receipt_summary(receipt, status)},
      {"expected_behavior",
       string_field(attrs, "expected_behavior") || "Preserve recorded final status #{status}."},
      {"verdict", string_field(attrs, "verdict") || "inconclusive"},
      {"trace", receipt_trace(pattern_id, receipt_id, stream_policy)},
      {"receipt_preview", receipt_preview(receipt, stream_policy, status)}
    ])
  end

  defp receipt_trace(pattern_id, receipt_id, stream_policy) do
    events = list_field(stream_policy, "events")

    events
    |> Enum.with_index(1)
    |> Enum.map(&receipt_trace_event(pattern_id, receipt_id, &1))
    |> case do
      [] -> [receipt_trace_fallback(pattern_id, receipt_id, stream_policy)]
      trace -> trace
    end
  end

  defp receipt_trace_event(pattern_id, receipt_id, {event, index}) when is_map(event) do
    type = string_field(event, "type") || "receipt.event"
    rule_id = string_field(event, "rule_id")

    Map.new([
      {"id", "#{receipt_id}:event:#{index}"},
      {"phase", receipt_phase(type)},
      {"node_id", receipt_node_id(rule_id, type)},
      {"kind", "receipt_event"},
      {"label", type},
      {"detail", string_field(event, "action") || string_field(event, "status") || type},
      {"severity", receipt_severity(type)},
      {"state_id", receipt_state(pattern_id, type)}
    ])
  end

  defp receipt_trace_event(pattern_id, receipt_id, {_event, index}) do
    receipt_trace_fallback(pattern_id, "#{receipt_id}:event:#{index}", %{})
  end

  defp receipt_trace_fallback(pattern_id, receipt_id, stream_policy) do
    status = string_field(stream_policy, "status") || "receipt imported"

    Map.new([
      {"id", "#{receipt_id}:final"},
      {"phase", "receipt.final"},
      {"node_id", "receipt.import"},
      {"kind", "receipt_import"},
      {"label", "receipt import"},
      {"detail", status},
      {"severity", "info"},
      {"state_id", receipt_state(pattern_id, "receipt.final")}
    ])
  end

  defp receipt_preview(receipt, stream_policy, status) do
    Map.new([
      {"receipt_id", string_field(receipt, "receipt_id")},
      {"final_status", status},
      {"stream_policy_status", string_field(stream_policy, "status")},
      {"retry_count", integer_field(stream_policy, "retry_count")},
      {"released_to_consumer", boolean_or_nil(stream_policy, "released_to_consumer")}
    ])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp receipt_summary(receipt, status) do
    model = string_field(receipt, "synthetic_model") || "unknown model"
    "Imported receipt for #{model} with final status #{status}."
  end

  defp receipt_phase("stream_policy." <> _rest), do: "response.streaming"
  defp receipt_phase("attempt." <> _rest), do: "response.streaming"
  defp receipt_phase(_type), do: "receipt.final"

  defp receipt_node_id(rule_id, _type) when is_binary(rule_id) and rule_id != "", do: rule_id
  defp receipt_node_id(_rule_id, type), do: type

  defp receipt_severity("stream_policy.triggered"), do: "warn"
  defp receipt_severity("stream_policy.latency_exceeded"), do: "fail"
  defp receipt_severity("attempt.retry_requested"), do: "pass"
  defp receipt_severity(_type), do: "info"

  defp receipt_state("tts-retry", "stream_policy.triggered"), do: "guarding"
  defp receipt_state("tts-retry", "attempt.retry_requested"), do: "retrying"
  defp receipt_state("tts-retry", _type), do: "recording"
  defp receipt_state(_pattern_id, _type), do: "active"

  defp integer_field(map, key) do
    case json_get(map, key) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp boolean_or_nil(map, key) do
    case json_get(map, key) do
      value when is_boolean(value) -> value
      _ -> nil
    end
  end

  defp json_get(map, key) when is_map(map), do: Map.get(map, key)
  defp json_get(_value, _key), do: nil
end
