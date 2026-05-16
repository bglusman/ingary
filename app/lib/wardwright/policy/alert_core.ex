defmodule Wardwright.Policy.AlertCore do
  @moduledoc false

  def decide_enqueue(config, queue_depth, already_seen, event, existing_status \\ :enqueued) do
    config = config_tuple(config)
    queue_depth = max(0, integer_value(queue_depth))
    already_seen = already_seen == true
    alert = alert_tuple(event)

    :wardwright@alert_core.decide_enqueue(
      config,
      queue_depth,
      already_seen,
      alert,
      existing_status
    )
    |> decision_map()
  end

  def terminal?(status) do
    :wardwright@alert_core.terminal(status)
  end

  defp config_tuple(config) do
    {
      :config,
      max(0, integer_value(config["capacity"])),
      on_full_atom(config["on_full"]),
      :fast,
      0
    }
  end

  defp alert_tuple(event) do
    {
      :alert,
      string_value(event["idempotency_key"]),
      string_value(event["rule_id"]),
      string_value(event["session_id"])
    }
  end

  defp decision_map({:enqueue_decision, key, status, queue_depth, queue_capacity}) do
    %{
      key: key,
      status: status,
      outcome: outcome(status),
      queue_depth: queue_depth,
      queue_capacity: queue_capacity
    }
  end

  defp outcome(:enqueued), do: "queued"
  defp outcome({:duplicate, _status}), do: "duplicate_suppressed"
  defp outcome(:dead_lettered), do: "dead_lettered"
  defp outcome(:dropped), do: "dropped"
  defp outcome(:blocked), do: "failed_closed"
  defp outcome(_status), do: "failed_closed"

  defp on_full_atom("drop"), do: :drop
  defp on_full_atom("fail_closed"), do: :fail_closed
  defp on_full_atom(_value), do: :dead_letter

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(_value), do: 0

  defp string_value(value) when is_binary(value), do: value
  defp string_value(nil), do: ""
  defp string_value(value), do: to_string(value)
end
