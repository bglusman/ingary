defmodule Wardwright.Policy.History do
  @moduledoc false

  alias Wardwright.Policy.Regex, as: PolicyRegex

  def record_request(caller, request) do
    add_text_event(
      "request_text",
      "chat_completion",
      caller,
      request_text(Map.get(request, "messages", []))
    )
  end

  def record_response(caller, content) when is_binary(content) and content != "" do
    add_text_event("response_text", "chat_completion", caller, content)
  end

  def record_response(_caller, _content), do: :ok

  def count(filter), do: Wardwright.PolicyCache.count(filter)

  def regex_count(filter, pattern, limit \\ nil) do
    filter
    |> Wardwright.PolicyCache.recent(limit)
    |> PolicyRegex.count_matches(pattern)
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
