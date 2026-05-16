defmodule Wardwright.ToolContext do
  @moduledoc """
  Boundary parser for tool-call-aware policy facts.

  Provider and agent APIs expose tool use differently. This module lowers the
  request-visible forms into a small Wardwright shape before policy planning,
  history, receipts, or UI projection consume tool facts.
  """

  @schema "wardwright.tool_context.v1"
  @phases ["planning", "argument_repair", "result_interpretation", "loop_governance", "unknown"]
  @sources [
    "declared_tool",
    "tool_choice",
    "assistant_tool_call",
    "tool_result",
    "caller_metadata",
    "inferred"
  ]
  @risk_classes ["read_only", "write", "irreversible", "external_side_effect", "unknown"]
  @confidences ["exact", "declared", "inferred", "ambiguous"]

  def normalize_request(request) when is_map(request) do
    tool_context = normalize(request)

    if tool_context do
      metadata =
        request
        |> Map.get("metadata", %{})
        |> case do
          metadata when is_map(metadata) -> metadata
          _ -> %{}
        end
        |> Map.put("tool_context", tool_context)

      {Map.put(request, "metadata", metadata), tool_context}
    else
      {request, nil}
    end
  end

  def normalize_request(request), do: {request, nil}

  def normalize(request) when is_map(request) do
    metadata_context = metadata_tool_context(request)
    inferred_context = infer_tool_context(request)

    metadata_context
    |> merge_inferred(inferred_context)
    |> reject_empty()
  end

  def normalize(_request), do: nil

  def cache_key(%{
        "primary_tool" => %{"namespace" => namespace, "name" => name},
        "phase" => phase
      })
      when is_binary(namespace) and is_binary(name) do
    [namespace, name, phase || "unknown"]
    |> Enum.map(&String.trim(to_string(&1)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(":")
  end

  def cache_key(_tool_context), do: nil

  def matches?(tool_context, matcher) when is_map(tool_context) and is_map(matcher) do
    tool = Map.get(tool_context, "primary_tool", %{})
    phases = string_list(Map.get(matcher, "phase", Map.get(matcher, "phases")))
    namespaces = string_list(Map.get(matcher, "namespace", Map.get(matcher, "namespaces")))
    names = string_list(Map.get(matcher, "name", Map.get(matcher, "names")))
    risks = string_list(Map.get(matcher, "risk_class", Map.get(matcher, "risk_classes")))

    list_match?(phases, Map.get(tool_context, "phase")) and
      list_match?(namespaces, Map.get(tool, "namespace")) and
      list_match?(names, Map.get(tool, "name")) and
      list_match?(risks, Map.get(tool, "risk_class"))
  end

  def matches?(_tool_context, _matcher), do: false

  defp metadata_tool_context(request) do
    request
    |> Map.get("metadata", %{})
    |> case do
      %{"tool_context" => tool_context} when is_map(tool_context) ->
        normalize_tool_context(tool_context, "caller_metadata")

      _ ->
        nil
    end
  end

  defp infer_tool_context(request) do
    available_tools = available_tools(request)
    tool_result = tool_result_context(request)
    assistant_tool_call = assistant_tool_call_context(request)
    choice_tool = tool_choice_context(request, available_tools)

    cond do
      tool_result -> Map.put(tool_result, "available_tools", available_tools)
      assistant_tool_call -> Map.put(assistant_tool_call, "available_tools", available_tools)
      choice_tool -> Map.put(choice_tool, "available_tools", available_tools)
      available_tools != [] -> declared_tools_context(available_tools)
      true -> nil
    end
  end

  defp available_tools(request) do
    request
    |> Map.get("tools", [])
    |> case do
      tools when is_list(tools) -> tools
      _ -> []
    end
    |> Enum.map(&tool_identity_from_definition/1)
    |> Enum.reject(&is_nil/1)
  end

  defp declared_tools_context([tool]) do
    %{
      "schema" => @schema,
      "phase" => "planning",
      "primary_tool" => Map.put_new(tool, "source", "declared_tool"),
      "available_tools" => [tool],
      "confidence" => "declared"
    }
  end

  defp declared_tools_context(tools) when is_list(tools) and tools != [] do
    %{
      "schema" => @schema,
      "phase" => "planning",
      "available_tools" => tools,
      "confidence" => "ambiguous"
    }
  end

  defp declared_tools_context(_tools), do: nil

  defp tool_choice_context(request, available_tools) do
    case Map.get(request, "tool_choice") do
      %{"type" => "function", "function" => %{"name" => name}} ->
        tool_context_from_name(name, "tool_choice", available_tools)

      %{"function" => %{"name" => name}} ->
        tool_context_from_name(name, "tool_choice", available_tools)

      %{"type" => "custom", "custom" => %{"name" => name}} ->
        tool_context_from_name(name, "tool_choice", available_tools)

      %{"custom" => %{"name" => name}} ->
        tool_context_from_name(name, "tool_choice", available_tools)

      _ ->
        nil
    end
  end

  defp assistant_tool_call_context(request) do
    request
    |> tool_calls()
    |> List.first()
    |> case do
      nil ->
        nil

      call ->
        tool =
          call
          |> tool_identity_from_call()
          |> Map.put_new("source", "assistant_tool_call")

        %{
          "schema" => @schema,
          "phase" => "planning",
          "primary_tool" => tool,
          "tool_call_id" => string_value(Map.get(call, "id")),
          "argument_hash" => argument_hash(call),
          "confidence" => "exact"
        }
        |> reject_blank()
    end
  end

  defp tool_result_context(request) do
    request
    |> messages()
    |> Enum.find(&(Map.get(&1, "role") == "tool"))
    |> case do
      nil ->
        nil

      message ->
        %{
          "schema" => @schema,
          "phase" => "result_interpretation",
          "tool_call_id" => string_value(Map.get(message, "tool_call_id")),
          "result_hash" => content_hash(Map.get(message, "content")),
          "result_status" => "unknown",
          "confidence" => "inferred"
        }
        |> maybe_put_result_tool(request)
        |> reject_blank()
    end
  end

  defp maybe_put_result_tool(context, request) do
    tool_call_id = Map.get(context, "tool_call_id")

    request
    |> tool_calls()
    |> Enum.find(&(string_value(Map.get(&1, "id")) == tool_call_id))
    |> case do
      nil ->
        context

      call ->
        tool =
          call
          |> tool_identity_from_call()
          |> Map.put_new("source", "tool_result")

        Map.put(context, "primary_tool", tool)
    end
  end

  defp tool_context_from_name(name, source, available_tools) do
    name = string_value(name)

    if name == "" do
      nil
    else
      tool =
        Enum.find(available_tools, &(Map.get(&1, "name") == name)) ||
          %{"namespace" => "openai.function", "name" => name}

      %{
        "schema" => @schema,
        "phase" => "planning",
        "primary_tool" => Map.put(tool, "source", source),
        "confidence" => "exact"
      }
    end
  end

  defp tool_identity_from_definition(%{"type" => "function", "function" => function})
       when is_map(function) do
    name = string_value(Map.get(function, "name"))

    if name == "" do
      nil
    else
      %{
        "namespace" => "openai.function",
        "name" => name,
        "display_name" => name,
        "source" => "declared_tool",
        "risk_class" => "unknown",
        "schema_hash" => schema_hash(Map.get(function, "parameters"))
      }
      |> reject_blank()
    end
  end

  defp tool_identity_from_definition(%{"type" => "custom", "custom" => custom})
       when is_map(custom) do
    name = string_value(Map.get(custom, "name"))

    if name == "" do
      nil
    else
      %{
        "namespace" => "openai.custom",
        "name" => name,
        "display_name" => name,
        "source" => "declared_tool",
        "risk_class" => "unknown"
      }
    end
  end

  defp tool_identity_from_definition(_tool), do: nil

  defp tool_identity_from_call(%{"type" => "function", "function" => function})
       when is_map(function) do
    name = string_value(Map.get(function, "name"))
    %{"namespace" => "openai.function", "name" => name, "risk_class" => "unknown"}
  end

  defp tool_identity_from_call(%{"type" => "custom", "custom" => custom}) when is_map(custom) do
    name = string_value(Map.get(custom, "name"))
    %{"namespace" => "openai.custom", "name" => name, "risk_class" => "unknown"}
  end

  defp tool_identity_from_call(_call), do: %{"namespace" => "unknown", "name" => "unknown"}

  defp tool_calls(request) do
    request
    |> messages()
    |> Enum.flat_map(fn
      %{"tool_calls" => calls} when is_list(calls) -> calls
      _ -> []
    end)
  end

  defp messages(%{"messages" => messages}) when is_list(messages), do: messages
  defp messages(_request), do: []

  defp normalize_tool_context(tool_context, source) do
    primary_tool =
      tool_context
      |> Map.get("primary_tool", %{})
      |> normalize_tool_identity(source)

    %{
      "schema" => @schema,
      "phase" => enum_value(Map.get(tool_context, "phase"), @phases, "unknown"),
      "primary_tool" => primary_tool,
      "tool_call_id" => string_value(Map.get(tool_context, "tool_call_id")),
      "available_tools" =>
        tool_context
        |> Map.get("available_tools", [])
        |> List.wrap()
        |> Enum.map(&normalize_tool_identity(&1, "declared_tool"))
        |> Enum.reject(&is_nil/1),
      "argument_hash" => hash_value(Map.get(tool_context, "argument_hash")),
      "result_hash" => hash_value(Map.get(tool_context, "result_hash")),
      "result_status" =>
        enum_value(
          Map.get(tool_context, "result_status"),
          [
            "success",
            "error",
            "timeout",
            "rejected",
            "unknown"
          ],
          "unknown"
        ),
      "confidence" => enum_value(Map.get(tool_context, "confidence"), @confidences, "exact")
    }
    |> reject_blank()
  end

  defp normalize_tool_identity(tool, source) when is_map(tool) do
    namespace = string_value(Map.get(tool, "namespace"))
    name = string_value(Map.get(tool, "name"))

    if namespace == "" or name == "" do
      nil
    else
      %{
        "namespace" => namespace,
        "name" => name,
        "display_name" => string_value(Map.get(tool, "display_name")),
        "source" => enum_value(Map.get(tool, "source"), @sources, source),
        "risk_class" => enum_value(Map.get(tool, "risk_class"), @risk_classes, "unknown"),
        "schema_hash" => hash_value(Map.get(tool, "schema_hash"))
      }
      |> reject_blank()
    end
  end

  defp normalize_tool_identity(_tool, _source), do: nil

  defp merge_inferred(nil, inferred), do: inferred
  defp merge_inferred(metadata, nil), do: metadata

  defp merge_inferred(metadata, inferred) do
    metadata
    |> Map.put_new("available_tools", Map.get(inferred, "available_tools", []))
    |> Map.put_new("argument_hash", Map.get(inferred, "argument_hash"))
    |> Map.put_new("result_hash", Map.get(inferred, "result_hash"))
    |> Map.put_new("result_status", Map.get(inferred, "result_status"))
    |> reject_blank()
  end

  defp reject_empty(nil), do: nil

  defp reject_empty(%{"primary_tool" => _tool} = context), do: context

  defp reject_empty(%{"available_tools" => [_ | _]} = context), do: context

  defp reject_empty(_context), do: nil

  defp list_match?([], _value), do: true
  defp list_match?(values, value), do: string_value(value) in values

  defp string_list(values) when is_list(values) do
    values
    |> Enum.map(&string_value/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp string_list(value) do
    value
    |> string_value()
    |> case do
      "" -> []
      value -> [value]
    end
  end

  defp argument_hash(%{"function" => %{"arguments" => arguments}}), do: content_hash(arguments)
  defp argument_hash(%{"custom" => %{"input" => input}}), do: content_hash(input)
  defp argument_hash(_call), do: nil

  defp content_hash(value) when value in [nil, ""], do: nil

  defp content_hash(value),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, canonical(value)), case: :lower)

  defp schema_hash(nil), do: nil
  defp schema_hash(value), do: content_hash(value)

  defp hash_value(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> nil
      String.starts_with?(value, "sha256:") -> value
      true -> content_hash(value)
    end
  end

  defp hash_value(_value), do: nil

  defp enum_value(value, allowed, default) do
    value = string_value(value)
    if value in allowed, do: value, else: default
  end

  defp canonical(value) when is_binary(value), do: value
  defp canonical(value), do: Jason.encode!(value)

  defp string_value(value) when is_binary(value), do: String.trim(value)
  defp string_value(value) when is_integer(value), do: Integer.to_string(value)
  defp string_value(value) when is_float(value), do: Float.to_string(value)
  defp string_value(value) when is_boolean(value), do: to_string(value)
  defp string_value(_value), do: ""

  defp reject_blank(map) when is_map(map) do
    map
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, ""} -> true
      {_key, []} -> true
      {_key, value} when is_map(value) and map_size(value) == 0 -> true
      {_key, _value} -> false
    end)
    |> Map.new()
  end
end
