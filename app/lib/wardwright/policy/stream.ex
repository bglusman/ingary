defmodule Wardwright.Policy.Stream do
  @moduledoc false

  alias Wardwright.Policy.Regex, as: PolicyRegex

  def evaluate(chunks, rules) when is_list(chunks) and is_list(rules) do
    chunks
    |> Enum.with_index()
    |> Enum.reduce_while(initial_result(), fn {chunk, index}, result ->
      stream_window = result.stream_buffer <> chunk

      case matching_rule(chunk, stream_window, rules) do
        nil ->
          {:cont, append_generated_chunk(result, chunk, chunk)}

        {rule, match_scope} ->
          apply_rule(result, chunk, stream_window, index, rule, match_scope)
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
      stream_buffer: "",
      released_to_consumer: true
    }
  end

  defp matching_rule(chunk, stream_window, rules) do
    Enum.find(rules, fn rule ->
      action = Map.get(rule, "action", "pass")

      action != "pass" and
        (contains_match?(chunk, Map.get(rule, "contains") || Map.get(rule, "pattern")) or
           regex_match?(chunk, Map.get(rule, "regex")) or
           terminal_stream_window_match?(action, stream_window, rule))
    end)
    |> case do
      nil -> nil
      rule -> {rule, match_scope(chunk, stream_window, rule)}
    end
  end

  defp apply_rule(result, chunk, stream_window, index, rule, match_scope) do
    action = Map.get(rule, "action", "annotate")
    event = event(rule, action, index, match_scope)

    result =
      result
      |> Map.update!(:trigger_count, &(&1 + 1))
      |> Map.update!(:events, &(&1 ++ [event]))
      |> Map.put(:action, action)

    case action do
      action when action in ["rewrite", "rewrite_chunk"] ->
        {:cont, append_generated_chunk(result, chunk, rewrite_chunk(chunk, rule))}

      "drop_chunk" ->
        {:cont, append_generated_chunk(result, chunk, nil)}

      action when action in ["block", "block_final"] ->
        {:halt,
         %{
           result
           | status: "stream_policy_blocked",
             chunks: [],
             stream_buffer: stream_window,
             released_to_consumer: false
         }}

      action when action in ["retry", "retry_with_reminder"] ->
        {:halt,
         %{
           result
           | status: "stream_policy_retry_required",
             chunks: [],
             stream_buffer: stream_window,
             released_to_consumer: false
         }}

      _ ->
        {:cont, append_generated_chunk(result, chunk, chunk)}
    end
  end

  defp append_generated_chunk(result, generated_chunk, nil),
    do: Map.update!(result, :stream_buffer, &(&1 <> generated_chunk))

  defp append_generated_chunk(result, generated_chunk, released_chunk) do
    result
    |> Map.update!(:stream_buffer, &(&1 <> generated_chunk))
    |> Map.update!(:chunks, &(&1 ++ [released_chunk]))
  end

  defp event(rule, action, index, match_scope) do
    %{
      "type" => "stream_policy.triggered",
      "rule_id" => Map.get(rule, "id", "stream-rule"),
      "action" => action,
      "chunk_index" => index,
      "match_scope" => match_scope
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

  defp terminal_stream_window_match?(action, stream_window, rule)
       when action in ["block", "block_final", "retry", "retry_with_reminder"] do
    contains_match?(stream_window, Map.get(rule, "contains") || Map.get(rule, "pattern")) or
      regex_match?(stream_window, Map.get(rule, "regex"))
  end

  defp terminal_stream_window_match?(_action, _stream_window, _rule), do: false

  defp match_scope(chunk, stream_window, rule) do
    if contains_match?(chunk, Map.get(rule, "contains") || Map.get(rule, "pattern")) or
         regex_match?(chunk, Map.get(rule, "regex")),
       do: "chunk",
       else: stream_window_scope(stream_window, rule)
  end

  defp stream_window_scope(stream_window, rule) do
    if contains_match?(stream_window, Map.get(rule, "contains") || Map.get(rule, "pattern")) or
         regex_match?(stream_window, Map.get(rule, "regex")),
       do: "stream_window",
       else: "chunk"
  end
end
