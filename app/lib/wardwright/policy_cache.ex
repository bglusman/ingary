defmodule Wardwright.PolicyCache do
  @moduledoc false

  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> initial_state(%{}) end, name: __MODULE__)
  end

  def configure(config) do
    Agent.update(__MODULE__, fn _state -> initial_state(config || %{}) end)
  end

  def add(input) when is_map(input) do
    Agent.get_and_update(__MODULE__, fn state ->
      with {:ok, event} <- build_event(input, state) do
        events = [event | state.events] |> evict(state.config)
        {{:ok, event}, %{state | next: state.next + 1, events: events}}
      else
        {:error, message} -> {{:error, message}, state}
      end
    end)
  end

  def recent(filter \\ %{}, limit \\ nil) do
    Agent.get(__MODULE__, fn state ->
      limit = normalize_limit(limit, state.config)

      state.events
      |> Enum.sort_by(& &1["sequence"], :desc)
      |> Enum.filter(&matches?(&1, filter || %{}))
      |> Enum.take(limit)
    end)
  end

  def count(filter \\ %{}) do
    Agent.get(__MODULE__, fn state ->
      Enum.count(state.events, &matches?(&1, filter || %{}))
    end)
  end

  def reset, do: configure(%{})

  defp initial_state(config) do
    %{config: normalize_config(config), next: 0, events: []}
  end

  defp normalize_config(config) do
    %{
      "max_entries" => positive_integer(config["max_entries"], 64),
      "recent_limit" => positive_integer(config["recent_limit"], 20)
    }
  end

  defp build_event(input, state) do
    kind = input |> Map.get("kind", "") |> to_string() |> String.trim()
    key = input |> Map.get("key", "") |> to_string() |> String.trim()
    created_at = integer_value(Map.get(input, "created_at_unix_ms", 0))

    cond do
      kind == "" ->
        {:error, "kind must not be empty"}

      created_at < 0 ->
        {:error, "created_at_unix_ms must not be negative"}

      state.config["max_entries"] < 1 ->
        {:error, "policy cache is disabled"}

      true ->
        sequence = state.next + 1

        {:ok,
         %{
           "id" => "pc_" <> String.pad_leading(Integer.to_string(sequence, 16), 16, "0"),
           "sequence" => sequence,
           "kind" => kind,
           "key" => key,
           "scope" => clean_scope(Map.get(input, "scope", %{})),
           "value" => Map.get(input, "value", %{}),
           "created_at_unix_ms" => created_at
         }}
    end
  end

  defp evict(events, config) do
    events
    |> Enum.sort_by(fn event -> {event["created_at_unix_ms"], event["sequence"]} end)
    |> Enum.take(-config["max_entries"])
  end

  defp matches?(event, filter) do
    scope = Map.get(filter, "scope", %{})

    (blank?(filter["kind"]) or event["kind"] == filter["kind"]) and
      (blank?(filter["key"]) or event["key"] == filter["key"]) and
      Enum.all?(scope, fn {key, value} -> get_in(event, ["scope", key]) == value end)
  end

  defp normalize_limit(nil, config), do: config["recent_limit"]

  defp normalize_limit(limit, config) do
    limit = positive_integer(limit, config["recent_limit"])
    min(limit, config["recent_limit"])
  end

  defp clean_scope(scope) when is_map(scope) do
    scope
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      key = key |> to_string() |> String.trim()
      value = value |> to_string() |> String.trim()

      if key == "" or value == "" do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp clean_scope(_), do: %{}

  defp blank?(value), do: value in [nil, ""]

  defp positive_integer(value, default) do
    case integer_value(value) do
      value when value > 0 -> value
      _ -> default
    end
  end

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  defp integer_value(_), do: 0
end
