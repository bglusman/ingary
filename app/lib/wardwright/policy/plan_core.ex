defmodule Wardwright.Policy.PlanCore do
  @moduledoc false

  def threshold(value) do
    value = integer_value(value)
    :wardwright@plan_core.threshold(value)
  end

  def threshold_triggered?(count, threshold) do
    count = integer_value(count)
    threshold = integer_value(threshold)
    :wardwright@plan_core.threshold_triggered(count, threshold)
  end

  def tool_policy_status(action) do
    action = to_string(action || "")
    :wardwright@plan_core.tool_policy_status(action)
  end

  def scope_label(value) do
    value = value |> blank_to_string()
    :wardwright@plan_core.scope_label(value)
  end

  def state_scope_matches?(required_state, current_state) do
    required_state = blank_to_string(required_state)
    current_state = blank_to_string(current_state)
    :wardwright@plan_core.state_scope_matches(required_state, current_state)
  end

  def sequence_window_limit(turns, events) do
    requested = integer_or_nil(turns) || integer_or_nil(events)
    has_requested = is_integer(requested)
    requested = requested || 0
    :wardwright@plan_core.sequence_window_limit(has_requested, requested)
  end

  def within_wall_clock_window?(max_ms, current_ms, prior_ms) do
    max_ms = integer_or_nil(max_ms)
    has_max_ms = is_integer(max_ms)
    max_ms = max_ms || 0
    current_ms = integer_value(current_ms)
    prior_ms = integer_value(prior_ms)

    :wardwright@plan_core.within_wall_clock_window(
      has_max_ms,
      max_ms,
      current_ms,
      prior_ms
    )
  end

  def event_after?(left_created_ms, left_sequence, right_created_ms, right_sequence) do
    left_created_ms = integer_value(left_created_ms)
    left_sequence = integer_value(left_sequence)
    right_created_ms = integer_value(right_created_ms)
    right_sequence = integer_value(right_sequence)

    :wardwright@plan_core.event_after(
      left_created_ms,
      left_sequence,
      right_created_ms,
      right_sequence
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
