defmodule Wardwright.Policy.StructuredCore do
  @moduledoc false

  alias Wardwright.Policy.CoreRuntime

  def guard_action do
    CoreRuntime.dispatch(
      :structured_guard_action,
      &:wardwright@structured_core.guard_action/0,
      fn ->
        "retry_with_validation_feedback"
      end
    )
  end

  def success_status(guard_count) when is_integer(guard_count) do
    CoreRuntime.dispatch(
      :structured_success_status,
      fn -> :wardwright@structured_core.success_status(guard_count) end,
      fn ->
        case guard_count do
          0 -> "completed"
          _ -> "completed_after_guard"
        end
      end
    )
  end

  def guard_rule_id_for_string(guard_type, schema_rule_id, semantic_rule_id) do
    guard_type = to_string(guard_type)
    schema_rule_id = to_string(schema_rule_id)
    semantic_rule_id = to_string(semantic_rule_id)

    CoreRuntime.dispatch(
      :structured_guard_rule_id,
      fn ->
        :wardwright@structured_core.guard_rule_id_for_string(
          guard_type,
          schema_rule_id,
          semantic_rule_id
        )
      end,
      fn ->
        case guard_type do
          "semantic_validation" -> semantic_rule_id
          _ -> schema_rule_id
        end
      end
    )
  end

  def loop_outcome_status(
        rule_id,
        rule_failures,
        max_failures_per_rule,
        attempt_count,
        max_attempts
      ) do
    rule_id = to_string(rule_id)
    rule_failures = integer_value(rule_failures)
    max_failures_per_rule = integer_value(max_failures_per_rule)
    attempt_count = integer_value(attempt_count)
    max_attempts = integer_value(max_attempts)

    CoreRuntime.dispatch(
      :structured_loop_outcome,
      fn ->
        :wardwright@structured_core.loop_outcome_status(
          rule_id,
          rule_failures,
          max_failures_per_rule,
          attempt_count,
          max_attempts
        )
      end,
      fn ->
        cond do
          rule_failures >= max_failures_per_rule -> "exhausted_rule_budget"
          attempt_count >= max_attempts -> "exhausted_guard_budget"
          true -> "continue"
        end
      end
    )
  end

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(_value), do: 0
end
