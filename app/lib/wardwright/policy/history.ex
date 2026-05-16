defmodule Wardwright.Policy.History do
  @moduledoc false

  alias Wardwright.Policy.Regex, as: PolicyRegex

  @kind_key "kind"
  @key_key "key"
  @scope_key "scope"
  @value_key "value"
  @created_at_key "created_at_unix_ms"
  @phase_key "phase"
  @primary_tool_key "primary_tool"
  @tool_call_id_key "tool_call_id"
  @tool_call_kind "tool_call"

  def record_request(caller, request) do
    add_text_event(
      "request_text",
      "chat_completion",
      caller,
      request_text(Map.get(request, "messages", []))
    )

    record_tool_context(caller, Wardwright.ToolContext.normalize(request))
  end

  def record_response(caller, content) when is_binary(content) and content != "" do
    add_text_event("response_text", "chat_completion", caller, content)
  end

  def record_response(_caller, _content), do: :ok

  def count(filter), do: Wardwright.PolicyCache.count(filter)

  def regex_count(filter, pattern, limit \\ nil) do
    matches =
      filter
      |> Wardwright.PolicyCache.recent(limit)
      |> Enum.map(fn event ->
        text =
          get_in(event, ["value", "text"]) ||
            get_in(event, ["value", "content"]) ||
            Map.get(event, "key", "")

        PolicyRegex.match?(to_string(text), pattern)
      end)

    Wardwright.Policy.HistoryCore.count_recent_matches(matches, recent_limit: length(matches))
  end

  def scope_from_caller(_caller, scope_name) when scope_name in [nil, ""], do: %{}

  def scope_from_caller(caller, scope_name) do
    scope_name = scope_name |> to_string() |> String.trim()

    case get_in(caller, [scope_name, "value"]) do
      nil -> %{}
      "" -> %{}
      value -> %{scope_name => value}
    end
  end

  defp add_text_event(kind, key, caller, text) do
    case Wardwright.PolicyCache.add(%{
           "kind" => kind,
           "key" => key,
           "scope" => caller_scope(caller),
           "value" => %{"text" => text},
           "created_at_unix_ms" => System.system_time(:millisecond)
         }) do
      {:ok, _event} -> :ok
      {:error, _message} -> :ok
    end
  end

  defp record_tool_context(_caller, nil), do: :ok

  defp record_tool_context(caller, tool_context) do
    case Wardwright.ToolContext.cache_key(tool_context) do
      nil ->
        :ok

      cache_key ->
        case Wardwright.PolicyCache.add(%{
               @kind_key => @tool_call_kind,
               @key_key => cache_key,
               @scope_key => caller_scope(caller),
               @value_key => tool_cache_value(tool_context),
               @created_at_key => System.system_time(:millisecond)
             }) do
          {:ok, _event} -> :ok
          {:error, _message} -> :ok
        end
    end
  end

  defp tool_cache_value(tool_context) do
    %{
      @phase_key => Map.get(tool_context, @phase_key),
      @primary_tool_key => Map.get(tool_context, @primary_tool_key),
      @tool_call_id_key => Map.get(tool_context, @tool_call_id_key)
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp caller_scope(caller) do
    [
      "tenant_id",
      "application_id",
      "consuming_agent_id",
      "consuming_user_id",
      "session_id",
      "run_id"
    ]
    |> Enum.reduce(%{}, fn key, acc ->
      case get_in(caller, [key, "value"]) do
        value when is_binary(value) and value != "" -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  defp request_text(messages) when is_list(messages) do
    Enum.map_join(messages, "\n", fn message ->
      "#{Map.get(message, "role", "")}\n#{metadata_string(Map.get(message, "content"))}"
    end)
  end

  defp request_text(_), do: ""

  defp metadata_string(value) when is_binary(value), do: String.trim(value)
  defp metadata_string(value) when is_integer(value), do: Integer.to_string(value)
  defp metadata_string(value) when is_float(value), do: Float.to_string(value)
  defp metadata_string(value) when is_boolean(value), do: to_string(value)
  defp metadata_string(_), do: ""
end
