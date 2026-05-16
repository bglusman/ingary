defmodule Wardwright.Policy.Action do
  @moduledoc """
  Normalized policy-action contract shared by primitive and sandboxed engines.

  Policy engines can return small maps, but the rest of the system should see a
  stable action shape with enough metadata for receipts, projection, simulation,
  and UI conflict explanation.
  """

  @schema "wardwright.policy_action.v1"
  @result_schema "wardwright.policy_result.v1"

  alias Wardwright.Policy.CoreRuntime

  def schema, do: @schema
  def result_schema, do: @result_schema

  def normalize(action, opts \\ [])

  def normalize(action, opts) when is_map(action) do
    rule = Keyword.get(opts, :rule, %{})
    source = Keyword.get(opts, :source, %{})
    kind = first_present([Map.get(action, "kind"), Map.get(rule, "kind"), "policy_engine"])
    name = first_present([Map.get(action, "action"), "annotate"])

    action
    |> Map.merge(%{
      "action_schema" => @schema,
      "rule_id" => first_present([Map.get(action, "rule_id"), Map.get(rule, "id"), "policy"]),
      "kind" => kind,
      "action" => name,
      "matched" => Map.get(action, "matched", true),
      "phase" => phase(kind, name),
      "effect_type" => effect_type(name),
      "source" => source(source, action),
      "priority" => priority(action, rule, name),
      "conflict_key" => conflict_key(name),
      "conflict_policy" => conflict_policy(name)
    })
    |> put_default_message(action)
    |> put_default_severity(action)
    |> reject_blank()
  end

  def normalize(_action, opts) do
    normalize(
      %{
        "action" => "annotate",
        "matched" => true,
        "message" => "policy engine returned a non-map action",
        "severity" => "warning"
      },
      opts
    )
  end

  def normalize_result(result, opts \\ [])

  def normalize_result(result, opts) when is_map(result) do
    rule = Keyword.get(opts, :rule, %{})
    engine = first_present([Map.get(result, "engine"), Map.get(rule, "engine"), "unknown"])
    status = first_present([Map.get(result, "status"), "ok"])
    source = %{"type" => "engine", "engine" => engine, "status" => status}

    actions =
      result
      |> raw_actions()
      |> Enum.map(&normalize(&1, rule: rule, source: source))

    %{
      "result_schema" => @result_schema,
      "engine" => engine,
      "status" => status,
      "action" => result_action(result, actions),
      "actions" => actions,
      "conflicts" => conflicts(actions)
    }
    |> put_if_present("reason", Map.get(result, "reason", Map.get(result, "message")))
    |> put_if_present("results", Map.get(result, "results"))
  end

  def normalize_result(_result, opts) do
    normalize_result(
      %{
        "engine" => "unknown",
        "status" => "error",
        "action" => "block",
        "reason" => "policy engine returned an invalid result"
      },
      opts
    )
  end

  def conflicts(actions) when is_list(actions) do
    actions
    |> Enum.group_by(&Map.get(&1, "conflict_key"))
    |> Enum.reject(fn {key, grouped} -> key in [nil, ""] or length(grouped) < 2 end)
    |> Enum.map(fn {key, grouped} ->
      policy = grouped |> List.first() |> Map.get("conflict_policy", "ordered")

      %{
        "conflict_schema" => "wardwright.policy_conflict.v1",
        "key" => key,
        "class" => policy,
        "action_count" => length(grouped),
        "rule_ids" => Enum.map(grouped, &Map.get(&1, "rule_id")),
        "summary" => conflict_summary(key, policy),
        "required_resolution" => conflict_resolution(policy)
      }
      |> reject_blank()
    end)
  end

  def conflicts(_actions), do: []

  defp raw_actions(%{"actions" => actions}) when is_list(actions), do: actions
  defp raw_actions(%{"action" => "allow"}), do: []
  defp raw_actions(%{"action" => action} = result) when is_binary(action), do: [result]
  defp raw_actions(_result), do: []

  defp result_action(result, actions) do
    status = Map.get(result, "status", "")
    blocking? = Enum.any?(actions, &(Map.get(&1, "action") == "block"))
    action_count = length(actions)

    CoreRuntime.dispatch(
      :action_result_action,
      fn -> :wardwright@action_core.result_action(status, blocking?, action_count) end,
      fn ->
        cond do
          status == "error" -> "block"
          blocking? -> "block"
          true -> "allow"
        end
      end
    )
  end

  defp phase(kind, action) do
    CoreRuntime.dispatch(
      :action_phase,
      fn -> :wardwright@action_core.phase(kind, action) end,
      fn ->
        cond do
          action in ["restrict_routes", "switch_model", "reroute"] -> "request.routing"
          action in ["inject_reminder_and_retry", "transform"] -> "request.rewrite"
          action in ["escalate", "alert_async"] -> "request.alert"
          action == "block" -> "request.terminal"
          kind in ["history_threshold", "history_regex_threshold"] -> "request.history"
          true -> "request.review"
        end
      end
    )
  end

  defp effect_type(action) do
    CoreRuntime.dispatch(
      :action_effect_type,
      fn -> :wardwright@action_core.effect_type(action) end,
      fn ->
        case action do
          "block" ->
            "terminal"

          action when action in ["restrict_routes", "switch_model", "reroute"] ->
            "route_constraint"

          action when action in ["inject_reminder_and_retry", "transform"] ->
            "request_transform"

          action when action in ["escalate", "alert_async"] ->
            "alert"

          "annotate" ->
            "annotation"

          _ ->
            "custom"
        end
      end
    )
  end

  defp conflict_key(action) do
    CoreRuntime.dispatch(
      :action_conflict_key,
      fn -> :wardwright@action_core.conflict_key(action) |> blank_to_nil() end,
      fn ->
        case action do
          "block" ->
            "terminal_decision"

          action when action in ["restrict_routes", "switch_model", "reroute"] ->
            "route_constraints"

          action when action in ["inject_reminder_and_retry", "transform"] ->
            "request_rewrite"

          _ ->
            nil
        end
      end
    )
  end

  defp conflict_policy(action) do
    CoreRuntime.dispatch(
      :action_conflict_policy,
      fn -> :wardwright@action_core.conflict_policy(action) end,
      fn -> if conflict_key(action), do: "ordered", else: "parallel_safe" end
    )
  end

  defp priority(action, rule, name) do
    first_present([
      integer_value(Map.get(action, "priority")),
      integer_value(Map.get(rule, "priority")),
      default_priority(name)
    ])
  end

  defp default_priority(action) do
    CoreRuntime.dispatch(
      :action_default_priority,
      fn -> :wardwright@action_core.default_priority(action) end,
      fn ->
        case action do
          "block" -> 10
          action when action in ["restrict_routes", "switch_model", "reroute"] -> 30
          action when action in ["inject_reminder_and_retry", "transform"] -> 50
          action when action in ["escalate", "alert_async"] -> 70
          _action -> 90
        end
      end
    )
  end

  defp source(_source, %{"source" => action_source}) when is_map(action_source),
    do: reject_blank(action_source)

  defp source(source, action) when is_map(source) and map_size(source) > 0 do
    source
    |> Map.put_new("engine", Map.get(action, "engine"))
    |> reject_blank()
  end

  defp source(_source, _action), do: %{"type" => "primitive"}

  defp put_default_message(action, original) do
    case first_present([Map.get(action, "message"), Map.get(action, "reason")]) do
      nil ->
        put_if_present(action, "message", Map.get(original, "reason"))

      value ->
        Map.put(action, "message", value)
    end
  end

  defp put_default_severity(action, original) do
    Map.put_new(action, "severity", first_present([Map.get(original, "severity"), "info"]))
  end

  defp conflict_summary("route_constraints", "ordered"),
    do: conflict_summary_core("route_constraints", "ordered")

  defp conflict_summary("terminal_decision", "ordered"),
    do: conflict_summary_core("terminal_decision", "ordered")

  defp conflict_summary(key, policy),
    do: conflict_summary_core(key, policy)

  defp conflict_resolution(policy) do
    CoreRuntime.dispatch(
      :action_conflict_resolution,
      fn -> :wardwright@action_core.conflict_resolution(policy) |> blank_to_nil() end,
      fn ->
        case policy do
          "ordered" -> "preserve policy declaration order"
          "parallel_safe" -> nil
          policy -> policy
        end
      end
    )
  end

  defp conflict_summary_core(key, policy) do
    CoreRuntime.dispatch(
      :action_conflict_summary,
      fn -> :wardwright@action_core.conflict_summary(key, policy) end,
      fn ->
        case {key, policy} do
          {"route_constraints", "ordered"} ->
            "Multiple route-affecting policy actions matched; declaration order resolves the final route constraints."

          {"terminal_decision", "ordered"} ->
            "Multiple terminal policy actions matched; fail-closed block semantics win."

          {key, policy} ->
            "Multiple policy actions share #{key}; resolution policy is #{policy}."
        end
      end
    )
  end

  defp first_present(values) do
    Enum.find(values, fn
      nil -> false
      "" -> false
      [] -> false
      _value -> true
    end)
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, _key, []), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp reject_blank(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
