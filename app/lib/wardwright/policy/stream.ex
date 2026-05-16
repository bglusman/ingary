defmodule Wardwright.Policy.Stream do
  @moduledoc false

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

  def consume(result, chunk, opts \\ [])

  def consume(result, _chunk, _opts) when is_map(result) and result.status != "completed" do
    {:halt, result, []}
  end

  def consume(result, chunk, opts) when is_map(result) do
    now_ms = now_ms(opts)
    before_chunks = result.chunks
    chunk_index = Map.get(result, :next_chunk_index, 0)
    stream_window_start_byte = Map.get(result, :stream_buffer_start_byte, 0)
    chunk_start_byte = stream_window_start_byte + byte_size(result.stream_buffer)
    chunk_end_byte = chunk_start_byte + byte_size(chunk)
    stream_window_end_byte = chunk_end_byte
    stream_window = result.stream_buffer <> chunk

    offset_context = %{
      chunk_start_byte: chunk_start_byte,
      chunk_end_byte: chunk_end_byte,
      stream_window_start_byte: stream_window_start_byte,
      stream_window_end_byte: stream_window_end_byte
    }

    {control, result} =
      case latency_exceeded_result(result, chunk, stream_window, chunk_index, now_ms) do
        nil ->
          case matching_rule(chunk, stream_window, result.rules, offset_context) do
            nil ->
              {:cont, append_unmatched_chunk(result, chunk, stream_window, now_ms)}

            {rule, match_info} ->
              apply_rule(result, chunk, stream_window, chunk_index, rule, match_info, now_ms)
          end

        result ->
          {:halt, result}
      end

    result =
      result
      |> Map.put(:next_chunk_index, chunk_index + 1)
      |> update_hold_age(now_ms)

    {control, result, released_since(before_chunks, result.chunks)}
  end

  def finish(result, opts \\ []) when is_map(result) do
    now_ms = now_ms(opts)
    before_chunks = result.chunks

    result =
      case latency_exceeded_result(
             result,
             "",
             result.stream_buffer,
             result.next_chunk_index,
             now_ms
           ) do
        nil -> finalize_result(result, now_ms)
        result -> result
      end

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
      stream_buffer_start_byte: 0,
      horizon_bytes: Keyword.get(opts, :horizon_bytes) || stream_horizon_bytes(rules),
      released_to_consumer: true,
      attempt_index: Keyword.get(opts, :attempt_index, 0),
      generated_bytes: 0,
      released_bytes: 0,
      held_bytes: 0,
      max_held_bytes: 0,
      max_hold_ms: Keyword.get(opts, :max_hold_ms) || stream_max_hold_ms(rules),
      hold_started_at_ms: nil,
      max_observed_hold_ms: 0,
      rewritten_bytes: 0,
      blocked_bytes: 0
    }
  end

  defp matching_rule(chunk, stream_window, rules, offset_context) do
    Enum.find_value(rules, fn rule ->
      action = Map.get(rule, "action", "pass")

      if action == "pass" do
        nil
      else
        match_info =
          match_info(chunk, rule, "chunk", offset_context.chunk_start_byte, offset_context) ||
            buffered_stream_window_match_info(
              action,
              stream_window,
              rule,
              offset_context.stream_window_start_byte,
              offset_context
            )

        if match_info, do: {rule, match_info}
      end
    end)
  end

  defp apply_rule(result, chunk, stream_window, index, rule, match_info, now_ms) do
    action = Map.get(rule, "action", "annotate")
    event = event(rule, action, index, match_info)

    result =
      result
      |> Map.update!(:trigger_count, &(&1 + 1))
      |> Map.update!(:events, &(&1 ++ [event]))
      |> Map.put(:action, action)

    case stream_action_tag(action, match_info.match_scope) do
      "rewrite_window" ->
        {:cont, rewrite_stream_window(result, chunk, stream_window, rule, now_ms)}

      "rewrite_chunk" ->
        if match_info.match_scope == "stream_window" do
          {:cont, rewrite_stream_window(result, chunk, stream_window, rule, now_ms)}
        else
          {:cont, append_rewritten_chunk(result, chunk, rewrite_chunk(chunk, rule), now_ms)}
        end

      "drop_chunk" ->
        {:cont, append_dropped_chunk(result, chunk, stream_window, now_ms)}

      "block" ->
        {:halt,
         terminal_result(result, chunk, stream_window, "stream_policy_blocked",
           blocked_bytes: byte_size(stream_window)
         )}

      "retry" ->
        {:halt, terminal_result(result, chunk, stream_window, "stream_policy_retry_required")}

      _ ->
        {:cont, append_unmatched_chunk(result, chunk, stream_window, now_ms)}
    end
  end

  defp append_unmatched_chunk(
         %{horizon_bytes: nil} = result,
         generated_chunk,
         _stream_window,
         now_ms
       ),
       do: append_generated_chunk(result, generated_chunk, generated_chunk, now_ms)

  defp append_unmatched_chunk(result, generated_chunk, stream_window, now_ms) do
    {released_chunk, held_window} = release_horizon_prefix(stream_window, result.horizon_bytes)

    result
    |> Map.put(:stream_buffer, held_window)
    |> advance_stream_buffer_start(released_chunk)
    |> maybe_append_released_chunk(released_chunk)
    |> add_generated_bytes(generated_chunk)
    |> add_released_bytes(released_chunk)
    |> update_max_held_bytes(held_window)
    |> update_hold_tracking(now_ms)
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

  defp append_dropped_chunk(
         %{horizon_bytes: nil} = result,
         generated_chunk,
         stream_window,
         now_ms
       ) do
    result
    |> Map.put(:stream_buffer, stream_window)
    |> add_generated_bytes(generated_chunk)
    |> update_max_held_bytes(stream_window)
    |> update_hold_tracking(now_ms)
  end

  defp append_dropped_chunk(result, generated_chunk, _stream_window, now_ms) do
    result
    |> add_generated_bytes(generated_chunk)
    |> update_max_held_bytes()
    |> update_hold_tracking(now_ms)
  end

  defp append_generated_chunk(result, generated_chunk, nil, now_ms),
    do:
      result
      |> Map.update!(:stream_buffer, &(&1 <> generated_chunk))
      |> add_generated_bytes(generated_chunk)
      |> update_max_held_bytes()
      |> update_hold_tracking(now_ms)

  defp append_generated_chunk(result, generated_chunk, released_chunk, now_ms) do
    result
    |> Map.update!(:stream_buffer, &(&1 <> generated_chunk))
    |> Map.update!(:chunks, &(&1 ++ [released_chunk]))
    |> add_generated_bytes(generated_chunk)
    |> Map.update!(:released_bytes, &(&1 + byte_size(released_chunk)))
    |> Map.update!(:rewritten_bytes, &(&1 + rewritten_bytes(generated_chunk, released_chunk)))
    |> update_max_held_bytes()
    |> update_hold_tracking(now_ms)
  end

  defp append_rewritten_chunk(
         %{horizon_bytes: nil} = result,
         generated_chunk,
         released_chunk,
         now_ms
       ) do
    result
    |> Map.update!(:stream_buffer, &(&1 <> released_chunk))
    |> Map.update!(:chunks, &(&1 ++ [released_chunk]))
    |> add_generated_bytes(generated_chunk)
    |> Map.update!(:released_bytes, &(&1 + byte_size(released_chunk)))
    |> Map.update!(:rewritten_bytes, &(&1 + rewritten_bytes(generated_chunk, released_chunk)))
    |> update_max_held_bytes()
    |> update_hold_tracking(now_ms)
  end

  defp append_rewritten_chunk(result, generated_chunk, released_chunk, now_ms) do
    stream_window = result.stream_buffer <> released_chunk
    {released_prefix, held_window} = release_horizon_prefix(stream_window, result.horizon_bytes)

    result
    |> Map.put(:stream_buffer, held_window)
    |> advance_stream_buffer_start(released_prefix)
    |> maybe_append_released_chunk(released_prefix)
    |> add_generated_bytes(generated_chunk)
    |> add_released_bytes(released_prefix)
    |> Map.update!(:rewritten_bytes, &(&1 + rewritten_bytes(generated_chunk, released_chunk)))
    |> update_max_held_bytes(held_window)
    |> update_hold_tracking(now_ms)
  end

  defp rewrite_stream_window(result, generated_chunk, stream_window, rule, now_ms) do
    released_chunk = rewrite_chunk(stream_window, rule)

    result
    |> put_rewritten_stream_window_chunk(released_chunk)
    |> add_generated_bytes(generated_chunk)
    |> Map.update!(:released_bytes, &(&1 + byte_size(released_chunk)))
    |> Map.update!(:rewritten_bytes, &(&1 + rewritten_bytes(stream_window, released_chunk)))
    |> update_max_held_bytes(stream_window)
    |> update_hold_tracking(now_ms)
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
    |> advance_stream_buffer_start(released_chunk)
    |> Map.update!(:chunks, &(&1 ++ [released_chunk]))
  end

  defp add_generated_bytes(result, generated_chunk) do
    Map.update!(result, :generated_bytes, &(&1 + byte_size(generated_chunk)))
  end

  defp maybe_append_released_chunk(result, ""), do: result

  defp maybe_append_released_chunk(result, released_chunk),
    do: Map.update!(result, :chunks, &(&1 ++ [released_chunk]))

  defp advance_stream_buffer_start(result, ""), do: result

  defp advance_stream_buffer_start(result, released_chunk) do
    Map.update(result, :stream_buffer_start_byte, byte_size(released_chunk), fn start_byte ->
      start_byte + byte_size(released_chunk)
    end)
  end

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

  defp update_hold_tracking(result, now_ms) do
    cond do
      result.stream_buffer == "" ->
        %{result | hold_started_at_ms: nil}

      is_integer(result.hold_started_at_ms) ->
        update_hold_age(result, now_ms)

      true ->
        %{result | hold_started_at_ms: now_ms}
    end
  end

  defp update_hold_age(%{hold_started_at_ms: started_at} = result, now_ms)
       when is_integer(started_at) do
    observed_ms = max(0, now_ms - started_at)
    Map.update!(result, :max_observed_hold_ms, &max(&1, observed_ms))
  end

  defp update_hold_age(result, _now_ms), do: result

  defp latency_exceeded_result(result, generated_chunk, stream_window, chunk_index, now_ms) do
    with max_hold_ms when is_integer(max_hold_ms) <- Map.get(result, :max_hold_ms),
         started_at when is_integer(started_at) <- Map.get(result, :hold_started_at_ms) do
      observed_ms = max(0, now_ms - started_at)

      if latency_exceeded?(observed_ms, max_hold_ms) do
        result =
          result
          |> Map.update!(:events, &(&1 ++ [latency_event(result, chunk_index, observed_ms)]))
          |> Map.put(:action, "fail_closed")
          |> Map.put(:max_observed_hold_ms, max(result.max_observed_hold_ms, observed_ms))

        terminal_result(result, generated_chunk, stream_window, "stream_policy_latency_exceeded")
      end
    end
  end

  defp latency_event(result, chunk_index, observed_ms) do
    %{
      "type" => "stream_policy.latency_exceeded",
      "action" => "fail_closed",
      "chunk_index" => chunk_index,
      "max_hold_ms" => result.max_hold_ms,
      "observed_hold_ms" => observed_ms,
      "held_bytes" => byte_size(result.stream_buffer)
    }
  end

  defp finalize_result(%{status: "completed", horizon_bytes: horizon} = result, now_ms)
       when is_integer(horizon) do
    result
    |> update_hold_age(now_ms)
    |> maybe_append_released_chunk(result.stream_buffer)
    |> add_released_bytes(result.stream_buffer)
    |> advance_stream_buffer_start(result.stream_buffer)
    |> Map.put(:stream_buffer, "")
    |> Map.put(:held_bytes, 0)
    |> update_hold_tracking(now_ms)
  end

  defp finalize_result(result, _now_ms), do: result

  defp event(rule, action, index, match_info) do
    %{
      "type" => "stream_policy.triggered",
      "rule_id" => Map.get(rule, "id", "stream-rule"),
      "action" => action,
      "chunk_index" => index,
      "match_scope" => match_info.match_scope,
      "match_kind" => match_info.match_kind,
      "chunk_start_byte" => match_info.chunk_start_byte,
      "chunk_end_byte" => match_info.chunk_end_byte,
      "stream_window_start_byte" => match_info.stream_window_start_byte,
      "stream_window_end_byte" => match_info.stream_window_end_byte,
      "match_start_byte" => match_info.match_start_byte,
      "match_end_byte" => match_info.match_end_byte,
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

  defp match_info(text, rule, scope, base_byte, offset_context) do
    match_info =
      literal_match_info(
        text,
        Map.get(rule, "contains") || Map.get(rule, "pattern"),
        scope,
        base_byte
      ) ||
        regex_match_info(text, Map.get(rule, "regex"), scope, base_byte)

    case match_info do
      nil -> nil
      match_info -> Map.merge(offset_context, match_info)
    end
  end

  defp literal_match_info(_text, value, _scope, _base_byte) when value in [nil, ""], do: nil

  defp literal_match_info(text, value, scope, base_byte) do
    pattern = to_string(value)

    case :binary.match(text, pattern) do
      {relative_start, length} ->
        %{
          match_scope: scope,
          match_kind: "literal",
          match_start_byte: base_byte + relative_start,
          match_end_byte: base_byte + relative_start + length
        }

      :nomatch ->
        nil
    end
  end

  defp regex_match_info(_text, value, _scope, _base_byte) when value in [nil, ""], do: nil

  defp regex_match_info(text, value, scope, base_byte) do
    with {:ok, regex} <- Regex.compile(to_string(value)),
         [{relative_start, length} | _captures] <- Regex.run(regex, text, return: :index) do
      %{
        match_scope: scope,
        match_kind: "regex",
        match_start_byte: base_byte + relative_start,
        match_end_byte: base_byte + relative_start + length
      }
    else
      _ -> nil
    end
  end

  defp buffered_stream_window_match_info(action, stream_window, rule, base_byte, offset_context)
       when action in [
              "block",
              "block_final",
              "retry",
              "retry_with_reminder",
              "rewrite",
              "rewrite_chunk"
            ] do
    match_info(stream_window, rule, "stream_window", base_byte, offset_context)
  end

  defp buffered_stream_window_match_info(
         _action,
         _stream_window,
         _rule,
         _base_byte,
         _offset_context
       ),
       do: nil

  defp rewritten_bytes(generated_chunk, released_chunk) do
    :wardwright@stream_core.rewritten_bytes(
      byte_size(generated_chunk),
      generated_chunk == released_chunk
    )
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

  defp stream_max_hold_ms(rules) do
    rules
    |> Enum.reject(&(Map.get(&1, "action", "pass") == "pass"))
    |> Enum.map(&non_negative_integer(Map.get(&1, "max_hold_ms")))
    |> Enum.filter(&is_integer/1)
    |> case do
      [] -> nil
      budgets -> Enum.min(budgets)
    end
  end

  defp release_horizon_prefix(stream_window, horizon_bytes)
       when is_integer(horizon_bytes) and horizon_bytes >= 0 do
    release_budget =
      :wardwright@stream_core.release_budget(byte_size(stream_window), horizon_bytes)

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

  defp now_ms(opts) do
    case Keyword.get(opts, :now_ms) do
      value when is_integer(value) -> value
      _ -> System.monotonic_time(:millisecond)
    end
  end

  defp non_negative_integer(value) do
    case integer_value(value) do
      integer when is_integer(integer) and integer >= 0 -> integer
      _ -> nil
    end
  end

  defp stream_action_tag(action, match_scope) do
    :wardwright@stream_core.action_tag(action, match_scope)
  end

  defp latency_exceeded?(observed_ms, max_hold_ms) do
    :wardwright@stream_core.latency_exceeded(observed_ms, max_hold_ms)
  end
end
