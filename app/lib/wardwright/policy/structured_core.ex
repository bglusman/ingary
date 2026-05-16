defmodule Wardwright.Policy.StructuredCore do
  @moduledoc false

  def guard_action, do: :wardwright@structured_core.guard_action()

  def success_status(guard_count) when is_integer(guard_count) do
    :wardwright@structured_core.success_status(guard_count)
  end

  def guard_rule_id_for_string(guard_type, schema_rule_id, semantic_rule_id) do
    guard_type = to_string(guard_type)
    schema_rule_id = to_string(schema_rule_id)
    semantic_rule_id = to_string(semantic_rule_id)

    :wardwright@structured_core.guard_rule_id_for_string(
      guard_type,
      schema_rule_id,
      semantic_rule_id
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

    :wardwright@structured_core.loop_outcome_status(
      rule_id,
      rule_failures,
      max_failures_per_rule,
      attempt_count,
      max_attempts
    )
  end

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(_value), do: 0
end
