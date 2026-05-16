defmodule Wardwright.Policy.Action do
  @moduledoc """
  Normalized policy-action contract shared by primitive and sandboxed engines.

  Policy engines can return small maps, but the rest of the system should see a
  stable action shape with enough metadata for receipts, projection, simulation,
  and UI conflict explanation.
  """

  @schema "wardwright.policy_action.v1"
  @result_schema "wardwright.policy_result.v1"

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

    :wardwright@action_core.result_action(status, blocking?, action_count)
  end

  defp phase(kind, action) do
    :wardwright@action_core.phase(kind, action)
  end

  defp effect_type(action) do
    :wardwright@action_core.effect_type(action)
  end

  defp conflict_key(action) do
    :wardwright@action_core.conflict_key(action) |> blank_to_nil()
  end

  defp conflict_policy(action) do
    :wardwright@action_core.conflict_policy(action)
  end

  defp priority(action, rule, name) do
    first_present([
      integer_value(Map.get(action, "priority")),
      integer_value(Map.get(rule, "priority")),
      default_priority(name)
    ])
  end

  defp default_priority(action) do
    :wardwright@action_core.default_priority(action)
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
    :wardwright@action_core.conflict_resolution(policy) |> blank_to_nil()
  end

  defp conflict_summary_core(key, policy) do
    :wardwright@action_core.conflict_summary(key, policy)
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
