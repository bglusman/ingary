defmodule Wardwright.Policy.PlanCore do
  @moduledoc false

  alias Wardwright.Policy.CoreRuntime

  def threshold(value) do
    value = integer_value(value)

    CoreRuntime.dispatch(
      :plan_threshold,
      fn -> :wardwright@plan_core.threshold(value) end,
      fn -> max(1, value) end
    )
  end

  def threshold_triggered?(count, threshold) do
    count = integer_value(count)
    threshold = integer_value(threshold)

    CoreRuntime.dispatch(
      :plan_threshold_triggered,
      fn -> :wardwright@plan_core.threshold_triggered(count, threshold) end,
      fn -> max(0, count) >= max(1, threshold) end
    )
  end

  def tool_policy_status(action) do
    action = to_string(action || "")

    CoreRuntime.dispatch(
      :plan_tool_policy_status,
      fn -> :wardwright@plan_core.tool_policy_status(action) end,
      fn ->
        case action do
          "block" -> "blocked"
          action when action in ["restrict_routes", "switch_model", "reroute"] -> "rerouted"
          action when action in ["escalate", "alert_async"] -> "alerted"
          action when action in ["inject_reminder_and_retry", "transform"] -> "transformed"
          _ -> "allowed"
        end
      end
    )
  end

  def scope_label(value) do
    value = value |> blank_to_string()

    CoreRuntime.dispatch(
      :plan_scope_label,
      fn -> :wardwright@plan_core.scope_label(value) end,
      fn ->
        case value do
          "" -> "session"
          "session_id" -> "session"
          "run_id" -> "run"
          value -> value
        end
      end
    )
  end

  def state_scope_matches?(required_state, current_state) do
    required_state = blank_to_string(required_state)
    current_state = blank_to_string(current_state)

    CoreRuntime.dispatch(
      :plan_state_scope_matches,
      fn -> :wardwright@plan_core.state_scope_matches(required_state, current_state) end,
      fn ->
        case required_state do
          "" -> true
          "active" -> current_state == "active"
          state -> current_state == state
        end
      end
    )
  end

  def sequence_window_limit(turns, events) do
    requested = integer_or_nil(turns) || integer_or_nil(events)
    has_requested = is_integer(requested)
    requested = requested || 0

    CoreRuntime.dispatch(
      :plan_sequence_window_limit,
      fn -> :wardwright@plan_core.sequence_window_limit(has_requested, requested) end,
      fn ->
        if has_requested, do: max(2, requested + 1), else: 21
      end
    )
  end

  def within_wall_clock_window?(max_ms, current_ms, prior_ms) do
    max_ms = integer_or_nil(max_ms)
    has_max_ms = is_integer(max_ms)
    max_ms = max_ms || 0
    current_ms = integer_value(current_ms)
    prior_ms = integer_value(prior_ms)

    CoreRuntime.dispatch(
      :plan_within_wall_clock_window,
      fn ->
        :wardwright@plan_core.within_wall_clock_window(
          has_max_ms,
          max_ms,
          current_ms,
          prior_ms
        )
      end,
      fn ->
        if has_max_ms, do: current_ms - prior_ms <= max_ms, else: true
      end
    )
  end

  def event_after?(left_created_ms, left_sequence, right_created_ms, right_sequence) do
    left_created_ms = integer_value(left_created_ms)
    left_sequence = integer_value(left_sequence)
    right_created_ms = integer_value(right_created_ms)
    right_sequence = integer_value(right_sequence)

    CoreRuntime.dispatch(
      :plan_event_after,
      fn ->
        :wardwright@plan_core.event_after(
          left_created_ms,
          left_sequence,
          right_created_ms,
          right_sequence
        )
      end,
      fn -> {left_created_ms, left_sequence} > {right_created_ms, right_sequence} end
    )
  end

  defp blank_to_string(nil), do: ""
  defp blank_to_string(value), do: value |> to_string() |> String.trim()

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  defp integer_value(_value), do: 0

  defp integer_or_nil(value) when is_integer(value), do: value

  defp integer_or_nil(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp integer_or_nil(_value), do: nil
end
