defmodule Wardwright.Policy.AlertDelivery do
  @moduledoc false

  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> initial_state(%{}) end, name: __MODULE__)
  end

  def configure(config) do
    Agent.update(__MODULE__, fn _state -> initial_state(config || %{}) end)
  end

  def reset, do: configure(%{})

  def deliver(events, receipt_hint \\ nil) when is_list(events) do
    Agent.get_and_update(__MODULE__, fn state ->
      Enum.reduce(events, {state, []}, fn event, {state, results} ->
        {state, result} = deliver_one(state, event, receipt_hint)
        {state, [result | results]}
      end)
      |> then(fn {state, results} -> {Enum.reverse(results), state} end)
    end)
  end

  def fail_closed?(results), do: Enum.any?(results, &(&1["outcome"] == "failed_closed"))

  defp initial_state(config) do
    %{
      config: normalize_config(config),
      queue: [],
      seen: MapSet.new()
    }
  end

  defp normalize_config(config) do
    %{
      "capacity" => non_negative_integer(config["capacity"], 16),
      "on_full" => normalize_on_full(config["on_full"])
    }
  end

  defp deliver_one(state, event, receipt_hint) do
    key = idempotency_key(event, receipt_hint)

    cond do
      event["type"] != "policy.alert" ->
        {state, result(event, key, "not_alerting")}

      true ->
        decision =
          Wardwright.Policy.AlertCore.decide_enqueue(
            state.config,
            length(state.queue),
            MapSet.member?(state.seen, key),
            Map.put(event, "idempotency_key", key)
          )

        apply_delivery_decision(state, event, decision)
    end
  end

  defp apply_delivery_decision(state, event, %{key: key, outcome: "duplicate_suppressed"}) do
    {state, result(event, key, "duplicate_suppressed")}
  end

  defp apply_delivery_decision(state, event, %{key: key, outcome: "queued"}) do
    state =
      state
      |> Map.update!(:seen, &MapSet.put(&1, key))
      |> Map.update!(:queue, &(&1 ++ [key]))

    {state, result(event, key, "queued")}
  end

  defp apply_delivery_decision(state, event, %{key: key, outcome: outcome}) do
    {Map.update!(state, :seen, &MapSet.put(&1, key)), result(event, key, outcome)}
  end

  defp idempotency_key(event, receipt_hint) do
    event["idempotency_key"] ||
      Enum.join(
        [
          receipt_hint,
          event["rule_id"],
          event["message"],
          event["severity"]
        ],
        ":"
      )
  end

  defp result(event, key, outcome) do
    %{
      "rule_id" => event["rule_id"],
      "idempotency_key" => key,
      "outcome" => outcome
    }
  end

  defp normalize_on_full(value) when value in ["drop", "dead_letter", "fail_closed"], do: value
  defp normalize_on_full(_), do: "dead_letter"

  defp non_negative_integer(value, default) do
    case integer_value(value) do
      value when is_integer(value) and value >= 0 -> value
      _ -> default
    end
  end

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp integer_value(_), do: nil
end
