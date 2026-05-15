defmodule Wardwright.Policy.Engine do
  @moduledoc false

  def evaluate(%{"engine" => "primitive", "rules" => rules}, context) when is_list(rules) do
    %{"engine" => "primitive", "status" => "ok", "actions" => primitive_actions(rules, context)}
    |> Wardwright.Policy.Action.normalize_result()
  end

  def evaluate(%{"engine" => "dune", "source" => source} = policy, context)
      when is_binary(source) do
    source
    |> String.replace("__WARDWRIGHT_CONTEXT__", inspect(context, charlists: :as_lists))
    |> Wardwright.PolicySandbox.Dune.eval_string()
    |> normalize_dune_result()
    |> Wardwright.Policy.Action.normalize_result(rule: policy)
  end

  def evaluate(%{"engine" => "wasm"} = policy, _context) do
    Wardwright.PolicySandbox.Wasm.evaluate(policy)
    |> Wardwright.Policy.Action.normalize_result(rule: policy)
  end

  def evaluate(%{"engine" => "hybrid", "engines" => engines}, context) when is_list(engines) do
    results = Enum.map(engines, &evaluate(&1, context))

    engine_failed? = Enum.any?(results, &(Map.get(&1, "status") == "error"))

    blocking? =
      Enum.any?(results, fn result ->
        Map.get(result, "action") == "block" or
          Enum.any?(result_actions(result), &(Map.get(&1, "action") == "block"))
      end)

    %{
      "engine" => "hybrid",
      "status" => if(engine_failed?, do: "error", else: "ok"),
      "action" => if(engine_failed? or blocking?, do: "block", else: "allow"),
      "actions" => Enum.flat_map(results, &result_actions/1),
      "results" => results
    }
    |> Wardwright.Policy.Action.normalize_result()
  end

  def evaluate(_policy, _context) do
    %{
      "engine" => "unknown",
      "status" => "error",
      "action" => "block",
      "reason" => "unsupported policy engine"
    }
    |> Wardwright.Policy.Action.normalize_result()
  end

  defp primitive_actions(rules, context) do
    text = context |> Map.get("request_text", "") |> String.downcase()

    for rule <- rules,
        contains = Map.get(rule, "contains"),
        is_binary(contains),
        contains != "",
        String.contains?(text, String.downcase(contains)) do
      %{
        "rule_id" => Map.get(rule, "id", "primitive-rule"),
        "action" => Map.get(rule, "action", "annotate"),
        "matched" => true
      }
    end
  end

  defp result_actions(%{"actions" => actions}) when is_list(actions), do: actions

  defp result_actions(%{"action" => "allow"}), do: []

  defp result_actions(%{"action" => action} = result) when is_binary(action) do
    [
      %{
        "rule_id" => Map.get(result, "rule_id"),
        "action" => action,
        "matched" => true,
        "message" =>
          Map.get(result, "reason", Map.get(result, "message", "policy engine matched"))
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()
    ]
  end

  defp result_actions(_result), do: []

  defp normalize_dune_result(%{"status" => "ok", "value" => value} = result) when is_map(value) do
    result
    |> Map.put("action", Map.get(value, "action", value[:action] || "allow"))
    |> Map.put("reason", Map.get(value, "reason", value[:reason]))
    |> Map.put("message", Map.get(value, "message", value[:message]))
    |> Map.put("severity", Map.get(value, "severity", value[:severity]))
    |> Map.put("allowed_targets", Map.get(value, "allowed_targets", value[:allowed_targets]))
    |> Map.put(
      "target_model",
      Map.get(value, "target_model", value[:target_model] || value[:model])
    )
  end

  defp normalize_dune_result(%{"status" => "ok"} = result),
    do: Map.merge(result, %{"action" => "allow"})

  defp normalize_dune_result(%{"status" => "error"} = result) do
    result
    |> Map.put("action", "block")
    |> Map.put_new("reason", "dune policy failed closed")
  end
end
