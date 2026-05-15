defmodule Wardwright.Policy.Plan do
  @moduledoc """
  Request-policy evaluator boundary.

  The router should only collect request/caller context and serialize outcomes.
  This module owns the deterministic policy pass that turns configured governance
  rules into a transformed request, policy actions, route constraints, and trace
  events.
  """

  def evaluate_request(request, caller, config \\ Wardwright.current_config()) do
    text = request |> Map.get("messages", []) |> request_text() |> String.downcase()

    config
    |> Map.get("governance", [])
    |> Enum.reduce({request, empty_policy()}, fn rule, {request, policy} ->
      apply_rule(rule, text, caller, request, policy)
    end)
    |> then(fn {request, policy} ->
      policy =
        policy
        |> Map.update!("actions", &Enum.reverse/1)
        |> Map.update!("events", &Enum.reverse/1)

      {request, policy}
    end)
  end

  def empty_policy,
    do: %{
      "actions" => [],
      "events" => [],
      "alert_count" => 0,
      "route_constraints" => %{},
      "blocked" => false
    }

  defp apply_rule(rule, text, caller, request, policy) do
    kind = Map.get(rule, "kind", "")

    cond do
      Map.has_key?(rule, "engine") ->
        apply_engine_governance_rule(rule, caller, request, policy)

      kind == "history_threshold" ->
        apply_history_threshold_rule(rule, caller, request, policy)

      kind == "history_regex_threshold" ->
        apply_history_regex_threshold_rule(rule, caller, request, policy)

      kind in ["request_guard", "request_transform", "receipt_annotation", "route_gate"] &&
          policy_rule_matches?(text, rule) ->
        apply_primitive_governance_rule(rule, kind, request, policy)

      true ->
        {request, policy}
    end
  end

  defp apply_primitive_governance_rule(rule, kind, request, policy) do
    action = Map.get(rule, "action", "annotate")
    rule_id = Map.get(rule, "id", "policy")

    message =
      rule |> Map.get("message", "request policy matched") |> blank_to_nil() ||
        "request policy matched"

    severity = rule |> Map.get("severity", "info") |> blank_to_nil() || "info"

    action_record =
      %{
        "rule_id" => rule_id,
        "kind" => kind,
        "action" => action,
        "matched" => true,
        "message" => message,
        "severity" => severity
      }
      |> put_route_action_fields(rule)

    case action do
      action when action in ["escalate", "alert_async"] ->
        event = %{
          "type" => "policy.alert",
          "rule_id" => rule_id,
          "message" => message,
          "severity" => severity,
          "idempotency_key" => Map.get(rule, "idempotency_key")
        }

        {request,
         policy
         |> Map.update!("actions", &[action_record | &1])
         |> Map.update!("events", &[event | &1])
         |> Map.update!("alert_count", &(&1 + 1))}

      action when action in ["inject_reminder_and_retry", "transform"] ->
        reminder = rule |> Map.get("reminder", message) |> blank_to_nil() || message

        message_record = %{
          "role" => "system",
          "name" => "wardwright_policy_reminder",
          "content" => reminder
        }

        request =
          Map.update(request, "messages", [message_record], fn messages ->
            messages ++ [message_record]
          end)

        action_record = Map.put(action_record, "reminder_injected", true)
        {request, Map.update!(policy, "actions", &[action_record | &1])}

      "annotate" ->
        event = %{
          "type" => "policy.annotated",
          "rule_id" => rule_id,
          "message" => message,
          "severity" => severity
        }

        {request,
         policy
         |> Map.update!("actions", &[action_record | &1])
         |> Map.update!("events", &[event | &1])}

      action when action in ["restrict_routes", "switch_model", "reroute"] ->
        apply_route_action(request, policy, action_record)

      "block" ->
        apply_block_action(request, policy, action_record)

      _ ->
        {request, Map.update!(policy, "actions", &[action_record | &1])}
    end
  end

  defp apply_engine_governance_rule(rule, caller, request, policy) do
    context = %{
      "request_text" => request |> Map.get("messages", []) |> request_text(),
      "request" => request,
      "caller" => caller,
      "estimated_prompt_tokens" =>
        Wardwright.estimate_prompt_tokens(Map.get(request, "messages", []))
    }

    result = Wardwright.Policy.Engine.evaluate(rule, context)

    action_records =
      result
      |> engine_actions(rule)
      |> Enum.map(&put_route_action_fields/1)

    Enum.reduce(action_records, {request, policy}, fn action_record, {request, policy} ->
      case action_record["action"] do
        action when action in ["restrict_routes", "switch_model", "reroute"] ->
          apply_route_action(request, policy, action_record)

        "block" ->
          apply_block_action(request, policy, action_record)

        _ ->
          {request, Map.update!(policy, "actions", &[action_record | &1])}
      end
    end)
  end

  defp engine_actions(%{"actions" => actions}, rule) when is_list(actions) do
    Enum.map(actions, &engine_action_record(&1, rule))
  end

  defp engine_actions(%{"action" => action} = result, rule) when is_binary(action) do
    [engine_action_record(result, rule)]
  end

  defp engine_actions(_result, _rule), do: []

  defp engine_action_record(action, rule) when is_map(action) do
    value = Map.get(action, "value", %{})
    value = if is_map(value), do: value, else: %{}

    %{
      "rule_id" => Map.get(action, "rule_id", Map.get(rule, "id", "policy-engine")),
      "kind" => Map.get(rule, "kind", "policy_engine"),
      "action" => Map.get(action, "action", "annotate"),
      "matched" => Map.get(action, "matched", true),
      "message" =>
        Map.get(
          action,
          "message",
          Map.get(action, "reason", Map.get(value, "reason", "policy engine matched"))
        ),
      "severity" => Map.get(action, "severity", "info"),
      "allowed_targets" => Map.get(action, "allowed_targets", Map.get(value, "allowed_targets")),
      "target_model" =>
        Map.get(
          action,
          "target_model",
          Map.get(action, "model", Map.get(value, "target_model", Map.get(value, "model")))
        )
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  defp engine_action_record(_action, rule) do
    %{
      "rule_id" => Map.get(rule, "id", "policy-engine"),
      "kind" => Map.get(rule, "kind", "policy_engine"),
      "action" => "annotate",
      "matched" => true,
      "message" => "policy engine returned a non-map action",
      "severity" => "warning"
    }
  end

  defp apply_route_action(request, policy, action_record) do
    route_constraints =
      policy
      |> Map.get("route_constraints", %{})
      |> merge_route_constraints(action_record)

    policy =
      policy
      |> Map.put("route_constraints", route_constraints)
      |> Map.update!("actions", &[action_record | &1])

    {request, policy}
  end

  defp merge_route_constraints(route_constraints, %{"action" => "restrict_routes"} = action) do
    allowed_targets = normalize_string_list(Map.get(action, "allowed_targets"))

    if allowed_targets == [] do
      route_constraints
    else
      Map.update(route_constraints, "allowed_targets", allowed_targets, fn existing ->
        existing
        |> normalize_string_list()
        |> Enum.filter(&(&1 in allowed_targets))
      end)
    end
  end

  defp merge_route_constraints(route_constraints, %{"action" => action} = record)
       when action in ["switch_model", "reroute"] do
    target_model = record |> Map.get("target_model", Map.get(record, "model")) |> blank_to_nil()

    if target_model do
      Map.put(route_constraints, "forced_model", target_model)
    else
      route_constraints
    end
  end

  defp merge_route_constraints(route_constraints, _action), do: route_constraints

  defp apply_block_action(request, policy, action_record) do
    policy =
      policy
      |> Map.put("blocked", true)
      |> Map.update!("actions", &[action_record | &1])

    {request, policy}
  end

  defp put_route_action_fields(action_record, rule) do
    action_record
    |> maybe_put_string_list("allowed_targets", Map.get(rule, "allowed_targets"))
    |> maybe_put_string("target_model", Map.get(rule, "target_model", Map.get(rule, "model")))
  end

  defp put_route_action_fields(action_record),
    do: put_route_action_fields(action_record, action_record)

  defp maybe_put_string_list(map, key, value) do
    value = normalize_string_list(value)
    if value == [], do: map, else: Map.put(map, key, value)
  end

  defp maybe_put_string(map, key, value) do
    case blank_to_nil(value) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_string_list(_values), do: []

  defp apply_history_threshold_rule(rule, caller, request, policy) do
    threshold = max(1, integer_value(Map.get(rule, "threshold", 1)) || 1)

    filter = %{
      "kind" => blank_to_nil(Map.get(rule, "cache_kind")),
      "key" => blank_to_nil(Map.get(rule, "cache_key")),
      "scope" => cache_scope_from_caller(caller, Map.get(rule, "cache_scope", ""))
    }

    count = Wardwright.PolicyCache.count(filter)

    if not Wardwright.Policy.HistoryCore.triggered_count?(count, threshold) do
      {request, policy}
    else
      action = Map.get(rule, "action", "annotate")
      rule_id = Map.get(rule, "id", "policy")

      message =
        rule |> Map.get("message", "policy cache threshold matched") |> blank_to_nil() ||
          "policy cache threshold matched"

      severity = rule |> Map.get("severity", "info") |> blank_to_nil() || "info"

      action_record = %{
        "rule_id" => rule_id,
        "kind" => "history_threshold",
        "action" => action,
        "matched" => true,
        "message" => message,
        "severity" => severity,
        "cache_kind" => Map.get(rule, "cache_kind", ""),
        "cache_key" => Map.get(rule, "cache_key", ""),
        "cache_scope" => Map.get(rule, "cache_scope", ""),
        "history_count" => count,
        "threshold" => threshold
      }

      policy = Map.update!(policy, "actions", &[action_record | &1])

      if action in ["escalate", "alert_async"] do
        event = %{
          "type" => "policy.alert",
          "rule_id" => rule_id,
          "message" => message,
          "severity" => severity,
          "history_count" => count,
          "threshold" => threshold,
          "idempotency_key" => Map.get(rule, "idempotency_key")
        }

        {request,
         policy
         |> Map.update!("events", &[event | &1])
         |> Map.update!("alert_count", &(&1 + 1))}
      else
        {request, policy}
      end
    end
  end

  defp apply_history_regex_threshold_rule(rule, caller, request, policy) do
    threshold = max(1, integer_value(Map.get(rule, "threshold", 1)) || 1)

    filter = %{
      "kind" => blank_to_nil(Map.get(rule, "cache_kind")),
      "key" => blank_to_nil(Map.get(rule, "cache_key")),
      "scope" => cache_scope_from_caller(caller, Map.get(rule, "cache_scope", ""))
    }

    count =
      filter
      |> Wardwright.Policy.History.regex_count(
        Map.get(rule, "pattern", ""),
        Map.get(rule, "limit")
      )

    if not Wardwright.Policy.HistoryCore.triggered_count?(count, threshold) do
      {request, policy}
    else
      action = Map.get(rule, "action", "annotate")
      rule_id = Map.get(rule, "id", "policy")

      message =
        rule |> Map.get("message", "history regex threshold matched") |> blank_to_nil() ||
          "history regex threshold matched"

      severity = rule |> Map.get("severity", "info") |> blank_to_nil() || "info"

      action_record = %{
        "rule_id" => rule_id,
        "kind" => "history_regex_threshold",
        "action" => action,
        "matched" => true,
        "message" => message,
        "severity" => severity,
        "cache_kind" => Map.get(rule, "cache_kind", ""),
        "cache_key" => Map.get(rule, "cache_key", ""),
        "cache_scope" => Map.get(rule, "cache_scope", ""),
        "pattern" => Map.get(rule, "pattern", ""),
        "history_count" => count,
        "threshold" => threshold
      }

      policy = Map.update!(policy, "actions", &[action_record | &1])

      if action in ["escalate", "alert_async"] do
        event = %{
          "type" => "policy.alert",
          "rule_id" => rule_id,
          "message" => message,
          "severity" => severity,
          "history_count" => count,
          "threshold" => threshold,
          "idempotency_key" => Map.get(rule, "idempotency_key")
        }

        {request,
         policy
         |> Map.update!("events", &[event | &1])
         |> Map.update!("alert_count", &(&1 + 1))}
      else
        {request, policy}
      end
    end
  end

  defp policy_match?(_text, value) when value in [nil, ""], do: false

  defp policy_match?(text, value) do
    String.contains?(text, value |> metadata_string() |> String.downcase())
  end

  defp policy_rule_matches?(text, %{"regex" => regex}) when is_binary(regex) and regex != "" do
    Wardwright.Policy.Regex.match?(text, regex)
  end

  defp policy_rule_matches?(text, rule), do: policy_match?(text, Map.get(rule, "contains"))

  defp request_text(messages) when is_list(messages) do
    Enum.map_join(messages, "\n", fn message ->
      "#{Map.get(message, "role", "")}\n#{metadata_string(Map.get(message, "content"))}"
    end)
  end

  defp request_text(_), do: ""

  defp cache_scope_from_caller(_caller, scope_name) when scope_name in [nil, ""], do: %{}

  defp cache_scope_from_caller(caller, scope_name) do
    scope_name = metadata_string(scope_name)

    case get_in(caller, [scope_name, "value"]) do
      nil -> %{}
      "" -> %{}
      value -> %{scope_name => value}
    end
  end

  defp metadata_string(value) when is_binary(value), do: String.trim(value)
  defp metadata_string(value) when is_integer(value), do: Integer.to_string(value)
  defp metadata_string(value) when is_float(value), do: Float.to_string(value)
  defp metadata_string(value) when is_boolean(value), do: to_string(value)
  defp metadata_string(_), do: ""

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp integer_value(_), do: nil
end
