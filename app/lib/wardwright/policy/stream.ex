defmodule Wardwright.Policy.Stream do
  @moduledoc false

  alias Wardwright.Policy.Regex, as: PolicyRegex

  def evaluate(chunks, rules, opts \\ [])

  def evaluate(chunks, rules, opts) when is_list(chunks) and is_list(rules) do
    chunks
    |> Enum.reduce_while(start(rules, opts), fn chunk, result ->
      case consume(result, chunk) do
        {:cont, result, _released_chunks} ->
          {:cont, result}

        {:halt, result, _released_chunks} ->
          {:halt, result}
      end
    end)
    |> finish()
    |> elem(0)
  end

  def evaluate(chunks, _rules, opts), do: evaluate(chunks, [], opts)

  def start(rules, opts \\ []) when is_list(rules) do
    initial_result(rules, opts)
  end

  def consume(%{status: status} = result, _chunk) when status != "completed" do
    {:halt, result, []}
  end

  def consume(result, chunk) when is_map(result) do
    before_chunks = result.chunks
    chunk_index = Map.get(result, :next_chunk_index, 0)
    stream_window = result.stream_buffer <> chunk

    {control, result} =
      case matching_rule(chunk, stream_window, result.rules) do
        nil ->
          {:cont, append_unmatched_chunk(result, chunk, stream_window)}

        {rule, match_scope} ->
          apply_rule(result, chunk, stream_window, chunk_index, rule, match_scope)
      end

    result = Map.put(result, :next_chunk_index, chunk_index + 1)
    {control, result, released_since(before_chunks, result.chunks)}
  end

  def finish(result) when is_map(result) do
    before_chunks = result.chunks
    result = finalize_result(result)
    {result, released_since(before_chunks, result.chunks)}
  end

  defp initial_result(rules, opts) do
    %{
      status: "completed",
      chunks: [],
      rules: rules,
      next_chunk_index: 0,
      trigger_count: 0,
      action: nil,
      events: [],
      stream_buffer: "",
      horizon_bytes: Keyword.get(opts, :horizon_bytes) || stream_horizon_bytes(rules),
      released_to_consumer: true,
      attempt_index: Keyword.get(opts, :attempt_index, 0),
      generated_bytes: 0,
      released_bytes: 0,
      held_bytes: 0,
      max_held_bytes: 0,
      rewritten_bytes: 0,
      blocked_bytes: 0
    }
  end

  defp matching_rule(chunk, stream_window, rules) do
    Enum.find(rules, fn rule ->
      action = Map.get(rule, "action", "pass")

      action != "pass" and
        (contains_match?(chunk, Map.get(rule, "contains") || Map.get(rule, "pattern")) or
           regex_match?(chunk, Map.get(rule, "regex")) or
           buffered_stream_window_match?(action, stream_window, rule))
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
        if match_scope == "stream_window" do
          {:cont, rewrite_stream_window(result, chunk, stream_window, rule)}
        else
          {:cont, append_rewritten_chunk(result, chunk, rewrite_chunk(chunk, rule))}
        end

      "drop_chunk" ->
        {:cont, append_dropped_chunk(result, chunk, stream_window)}

      action when action in ["block", "block_final"] ->
        {:halt,
         terminal_result(result, chunk, stream_window, "stream_policy_blocked",
           blocked_bytes: byte_size(stream_window)
         )}

      action when action in ["retry", "retry_with_reminder"] ->
        {:halt, terminal_result(result, chunk, stream_window, "stream_policy_retry_required")}

      _ ->
        {:cont, append_unmatched_chunk(result, chunk, stream_window)}
    end
  end

  defp append_unmatched_chunk(%{horizon_bytes: nil} = result, generated_chunk, _stream_window),
    do: append_generated_chunk(result, generated_chunk, generated_chunk)

  defp append_unmatched_chunk(result, generated_chunk, stream_window) do
    {released_chunk, held_window} = release_horizon_prefix(stream_window, result.horizon_bytes)

    result
    |> Map.put(:stream_buffer, held_window)
    |> maybe_append_released_chunk(released_chunk)
    |> add_generated_bytes(generated_chunk)
    |> add_released_bytes(released_chunk)
    |> update_max_held_bytes(held_window)
  end

  defp terminal_result(
         %{horizon_bytes: nil} = result,
         generated_chunk,
         stream_window,
         status,
         opts
       ) do
    %{
      (result
       |> add_generated_bytes(generated_chunk))
      | status: status,
        chunks: [],
        stream_buffer: stream_window,
        released_to_consumer: false,
        released_bytes: 0,
        held_bytes: byte_size(stream_window),
        max_held_bytes: max(result.max_held_bytes, byte_size(stream_window)),
        blocked_bytes: Keyword.get(opts, :blocked_bytes, result.blocked_bytes)
    }
  end

  defp terminal_result(result, generated_chunk, stream_window, status, opts) do
    %{
      (result
       |> add_generated_bytes(generated_chunk))
      | status: status,
        stream_buffer: stream_window,
        released_to_consumer: false,
        held_bytes: byte_size(stream_window),
        max_held_bytes: max(result.max_held_bytes, byte_size(stream_window)),
        blocked_bytes: Keyword.get(opts, :blocked_bytes, result.blocked_bytes)
    }
  end

  defp terminal_result(result, generated_chunk, stream_window, status),
    do: terminal_result(result, generated_chunk, stream_window, status, [])

  defp append_dropped_chunk(%{horizon_bytes: nil} = result, generated_chunk, stream_window) do
    result
    |> Map.put(:stream_buffer, stream_window)
    |> add_generated_bytes(generated_chunk)
    |> update_max_held_bytes(stream_window)
  end

  defp append_dropped_chunk(result, generated_chunk, _stream_window) do
    result
    |> add_generated_bytes(generated_chunk)
    |> update_max_held_bytes()
  end

  defp append_generated_chunk(result, generated_chunk, nil),
    do:
      result
      |> Map.update!(:stream_buffer, &(&1 <> generated_chunk))
      |> add_generated_bytes(generated_chunk)
      |> update_max_held_bytes()

  defp append_generated_chunk(result, generated_chunk, released_chunk) do
    result
    |> Map.update!(:stream_buffer, &(&1 <> generated_chunk))
    |> Map.update!(:chunks, &(&1 ++ [released_chunk]))
    |> add_generated_bytes(generated_chunk)
    |> Map.update!(:released_bytes, &(&1 + byte_size(released_chunk)))
    |> Map.update!(:rewritten_bytes, &(&1 + rewritten_bytes(generated_chunk, released_chunk)))
    |> update_max_held_bytes()
  end

  defp append_rewritten_chunk(%{horizon_bytes: nil} = result, generated_chunk, released_chunk) do
    result
    |> Map.update!(:stream_buffer, &(&1 <> released_chunk))
    |> Map.update!(:chunks, &(&1 ++ [released_chunk]))
    |> add_generated_bytes(generated_chunk)
    |> Map.update!(:released_bytes, &(&1 + byte_size(released_chunk)))
    |> Map.update!(:rewritten_bytes, &(&1 + rewritten_bytes(generated_chunk, released_chunk)))
    |> update_max_held_bytes()
  end

  defp append_rewritten_chunk(result, generated_chunk, released_chunk) do
    stream_window = result.stream_buffer <> released_chunk
    {released_prefix, held_window} = release_horizon_prefix(stream_window, result.horizon_bytes)

    result
    |> Map.put(:stream_buffer, held_window)
    |> maybe_append_released_chunk(released_prefix)
    |> add_generated_bytes(generated_chunk)
    |> add_released_bytes(released_prefix)
    |> Map.update!(:rewritten_bytes, &(&1 + rewritten_bytes(generated_chunk, released_chunk)))
    |> update_max_held_bytes(held_window)
  end

  defp rewrite_stream_window(result, generated_chunk, stream_window, rule) do
    released_chunk = rewrite_chunk(stream_window, rule)

    result
    |> put_rewritten_stream_window_chunk(released_chunk)
    |> add_generated_bytes(generated_chunk)
    |> Map.update!(:released_bytes, &(&1 + byte_size(released_chunk)))
    |> Map.update!(:rewritten_bytes, &(&1 + rewritten_bytes(stream_window, released_chunk)))
    |> update_max_held_bytes(stream_window)
  end

  defp put_rewritten_stream_window_chunk(%{horizon_bytes: nil} = result, released_chunk) do
    result
    |> Map.put(:stream_buffer, released_chunk)
    |> Map.put(:chunks, [released_chunk])
    |> Map.put(:released_bytes, 0)
  end

  defp put_rewritten_stream_window_chunk(result, released_chunk) do
    result
    |> Map.put(:stream_buffer, "")
    |> Map.update!(:chunks, &(&1 ++ [released_chunk]))
  end

  defp add_generated_bytes(result, generated_chunk) do
    Map.update!(result, :generated_bytes, &(&1 + byte_size(generated_chunk)))
  end

  defp maybe_append_released_chunk(result, ""), do: result

  defp maybe_append_released_chunk(result, released_chunk),
    do: Map.update!(result, :chunks, &(&1 ++ [released_chunk]))

  defp released_since(before_chunks, after_chunks) do
    Enum.drop(after_chunks, length(before_chunks))
  end

  defp add_released_bytes(result, ""), do: result

  defp add_released_bytes(result, released_chunk),
    do: Map.update!(result, :released_bytes, &(&1 + byte_size(released_chunk)))

  defp update_max_held_bytes(result), do: update_max_held_bytes(result, result.stream_buffer)

  defp update_max_held_bytes(result, held_window) do
    Map.update!(result, :max_held_bytes, &max(&1, byte_size(held_window)))
  end

  defp finalize_result(%{status: "completed", horizon_bytes: horizon} = result)
       when is_integer(horizon) do
    result
    |> maybe_append_released_chunk(result.stream_buffer)
    |> add_released_bytes(result.stream_buffer)
    |> Map.put(:stream_buffer, "")
    |> Map.put(:held_bytes, 0)
  end

  defp finalize_result(result), do: result

  defp event(rule, action, index, match_scope) do
    %{
      "type" => "stream_policy.triggered",
      "rule_id" => Map.get(rule, "id", "stream-rule"),
      "action" => action,
      "chunk_index" => index,
      "match_scope" => match_scope,
      "reminder" => Map.get(rule, "reminder"),
      "max_retries" => integer_value(Map.get(rule, "max_retries"))
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
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

  defp buffered_stream_window_match?(action, stream_window, rule)
       when action in [
              "block",
              "block_final",
              "retry",
              "retry_with_reminder",
              "rewrite",
              "rewrite_chunk"
            ] do
    contains_match?(stream_window, Map.get(rule, "contains") || Map.get(rule, "pattern")) or
      regex_match?(stream_window, Map.get(rule, "regex"))
  end

  defp buffered_stream_window_match?(_action, _stream_window, _rule), do: false

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

  defp rewritten_bytes(generated_chunk, released_chunk) do
    if generated_chunk == released_chunk, do: 0, else: byte_size(generated_chunk)
  end

  defp stream_horizon_bytes([]), do: nil

  defp stream_horizon_bytes(rules) do
    rules
    |> Enum.reject(&(Map.get(&1, "action", "pass") == "pass"))
    |> Enum.map(&rule_horizon_bytes/1)
    |> case do
      [] -> nil
      horizons -> if Enum.all?(horizons, &is_integer/1), do: Enum.max(horizons), else: nil
    end
  end

  defp rule_horizon_bytes(rule) do
    rule
    |> Map.get("horizon_bytes")
    |> case do
      nil -> Map.get(rule, "holdback_bytes")
      value -> value
    end
    |> non_negative_integer()
  end

  defp release_horizon_prefix(stream_window, horizon_bytes)
       when is_integer(horizon_bytes) and horizon_bytes >= 0 do
    release_budget = max(byte_size(stream_window) - horizon_bytes, 0)
    split_prefix_at_byte_limit(stream_window, release_budget)
  end

  defp release_horizon_prefix(stream_window, _horizon_bytes), do: {"", stream_window}

  defp split_prefix_at_byte_limit(text, byte_limit) when byte_limit <= 0, do: {"", text}

  defp split_prefix_at_byte_limit(text, byte_limit) do
    graphemes = String.graphemes(text)

    {count, _bytes} =
      Enum.reduce_while(graphemes, {0, 0}, fn grapheme, {count, bytes} ->
        next_bytes = bytes + byte_size(grapheme)

        if next_bytes <= byte_limit do
          {:cont, {count + 1, next_bytes}}
        else
          {:halt, {count, bytes}}
        end
      end)

    {prefix, suffix} = Enum.split(graphemes, count)
    {Enum.join(prefix), Enum.join(suffix)}
  end

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp non_negative_integer(value) do
    case integer_value(value) do
      integer when is_integer(integer) and integer >= 0 -> integer
      _ -> nil
    end
  end
end
