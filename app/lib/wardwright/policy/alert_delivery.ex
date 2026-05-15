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

  def status do
    Agent.get(__MODULE__, fn state ->
      outcomes = state.outcomes

      %{
        "kind" => "in_memory_alert_sink",
        "capacity" => state.config["capacity"],
        "on_full" => state.config["on_full"],
        "queue_depth" => length(state.queue),
        "seen_count" => MapSet.size(state.seen),
        "queued_count" => Map.get(outcomes, "queued", 0),
        "dead_letter_count" => Map.get(outcomes, "dead_lettered", 0),
        "dropped_count" => Map.get(outcomes, "dropped", 0),
        "failed_closed_count" => Map.get(outcomes, "failed_closed", 0),
        "duplicate_suppressed_count" => Map.get(outcomes, "duplicate_suppressed", 0),
        "last_result" => state.last_result
      }
    end)
  end

  defp initial_state(config) do
    %{
      config: normalize_config(config),
      queue: [],
      seen: MapSet.new(),
      outcomes: %{},
      last_result: nil
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
    result = result(event, key, "duplicate_suppressed")
    {record_result(state, result), result}
  end

  defp apply_delivery_decision(state, event, %{key: key, outcome: "queued"}) do
    result = result(event, key, "queued")

    state =
      state
      |> Map.update!(:seen, &MapSet.put(&1, key))
      |> Map.update!(:queue, &(&1 ++ [key]))
      |> record_result(result)

    {state, result}
  end

  defp apply_delivery_decision(state, event, %{key: key, outcome: outcome}) do
    result = result(event, key, outcome)

    state =
      state
      |> Map.update!(:seen, &MapSet.put(&1, key))
      |> record_result(result)

    {state, result}
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

  defp record_result(state, result) do
    publish_result(state, result)

    state
    |> Map.update!(:outcomes, fn outcomes ->
      Map.update(outcomes, result["outcome"], 1, &(&1 + 1))
    end)
    |> Map.put(:last_result, result)
  end

  defp publish_result(state, result) do
    if Process.whereis(Wardwright.PubSub) do
      Wardwright.Runtime.Events.publish(Wardwright.Runtime.Events.topic(:policies), %{
        "type" => "policy_alert.delivery",
        "rule_id" => result["rule_id"],
        "idempotency_key" => result["idempotency_key"],
        "outcome" => result["outcome"],
        "queue_depth" => length(state.queue),
        "capacity" => state.config["capacity"],
        "created_at" => System.system_time(:second)
      })
    end
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
