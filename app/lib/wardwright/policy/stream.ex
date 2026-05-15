defmodule Wardwright.Policy.Stream do
  @moduledoc false

  alias Wardwright.Policy.Regex, as: PolicyRegex

  def evaluate(chunks, rules) when is_list(chunks) and is_list(rules) do
    chunks
    |> Enum.with_index()
    |> Enum.reduce_while(initial_result(), fn {chunk, index}, result ->
      case matching_rule(chunk, rules) do
        nil ->
          {:cont, append_chunk(result, chunk)}

        rule ->
          apply_rule(result, chunk, index, rule)
      end
    end)
  end

  def evaluate(chunks, _rules), do: evaluate(chunks, [])

  defp initial_result do
    %{
      status: "completed",
      chunks: [],
      trigger_count: 0,
      action: nil,
      events: [],
      released_to_consumer: true
    }
  end

  defp matching_rule(chunk, rules) do
    Enum.find(rules, fn rule ->
      action = Map.get(rule, "action", "pass")

      action != "pass" and
        (contains_match?(chunk, Map.get(rule, "contains") || Map.get(rule, "pattern")) or
           regex_match?(chunk, Map.get(rule, "regex")))
    end)
  end

  defp apply_rule(result, chunk, index, rule) do
    action = Map.get(rule, "action", "annotate")
    event = event(rule, action, index)

    result =
      result
      |> Map.update!(:trigger_count, &(&1 + 1))
      |> Map.update!(:events, &(&1 ++ [event]))
      |> Map.put(:action, action)

    case action do
      action when action in ["rewrite", "rewrite_chunk"] ->
        {:cont, append_chunk(result, rewrite_chunk(chunk, rule))}

      "drop_chunk" ->
        {:cont, result}

      action when action in ["block", "block_final"] ->
        {:halt,
         %{result | status: "stream_policy_blocked", chunks: [], released_to_consumer: false}}

      action when action in ["retry", "retry_with_reminder"] ->
        {:halt,
         %{
           result
           | status: "stream_policy_retry_required",
             chunks: [],
             released_to_consumer: false
         }}

      _ ->
        {:cont, append_chunk(result, chunk)}
    end
  end

  defp append_chunk(result, chunk), do: Map.update!(result, :chunks, &(&1 ++ [chunk]))

  defp event(rule, action, index) do
    %{
      "type" => "stream_policy.triggered",
      "rule_id" => Map.get(rule, "id", "stream-rule"),
      "action" => action,
      "chunk_index" => index
    }
  end

  defp rewrite_chunk(chunk, rule) do
    replacement = Map.get(rule, "replacement", "[redacted]")

    cond do
      is_binary(rule["regex"]) and rule["regex"] != "" ->
        case Regex.compile(rule["regex"]) do
          {:ok, regex} -> Regex.replace(regex, chunk, replacement)
          {:error, _} -> chunk
        end

      is_binary(rule["contains"]) and rule["contains"] != "" ->
        String.replace(chunk, rule["contains"], replacement)

      is_binary(rule["pattern"]) and rule["pattern"] != "" ->
        String.replace(chunk, rule["pattern"], replacement)

      true ->
        chunk
    end
  end

  defp contains_match?(_chunk, value) when value in [nil, ""], do: false
  defp contains_match?(chunk, value), do: String.contains?(chunk, to_string(value))

  defp regex_match?(_chunk, value) when value in [nil, ""], do: false
  defp regex_match?(chunk, value), do: PolicyRegex.match?(chunk, value)
end
