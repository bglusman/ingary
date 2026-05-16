defmodule Wardwright.ToolContext do
  @moduledoc """
  Boundary normalizer for tool context facts carried by model requests.

  The normalized map is receipt evidence only for now. Policy selectors and
  counters can depend on this shape once the tool-policy contract stabilizes.
  """

  @schema "wardwright.tool_context.v1"
  @argument_hash_key "argument_hash"
  @available_tools_key "available_tools"
  @confidence_key "confidence"
  @function_key "function"
  @metadata_key "metadata"
  @id_key "id"
  @messages_key "messages"
  @name_key "name"
  @namespace_key "namespace"
  @phase_key "phase"
  @primary_tool_key "primary_tool"
  @result_hash_key "result_hash"
  @result_status_key "result_status"
  @risk_class_key "risk_class"
  @role_key "role"
  @schema_hash_key "schema_hash"
  @schema_key "schema"
  @source_key "source"
  @tool_call_id_key "tool_call_id"
  @tool_calls_key "tool_calls"
  @tool_choice_key "tool_choice"
  @tool_context_key "tool_context"
  @tools_key "tools"
  @type_key "type"
  @tool_role "tool"

  @confidence_ambiguous "ambiguous"
  @confidence_declared "declared"
  @confidence_exact "exact"
  @confidence_inferred "inferred"
  @namespace_openai_function "openai.function"
  @namespace_openai_tool "openai.tool"
  @phase_planning "planning"
  @phase_result_interpretation "result_interpretation"
  @phase_unknown "unknown"
  @risk_unknown "unknown"
  @source_assistant_tool_call "assistant_tool_call"
  @source_caller_metadata "caller_metadata"
  @source_declared_tool "declared_tool"
  @source_tool_choice "tool_choice"

  @confidence_values MapSet.new(~w(exact declared inferred ambiguous))
  @phase_values MapSet.new(
                  ~w(planning argument_repair result_interpretation loop_governance unknown)
                )
  @result_status_values MapSet.new(~w(success error timeout rejected unknown))
  @risk_values MapSet.new(~w(read_only write irreversible external_side_effect unknown))
  @source_values MapSet.new(
                   ~w(declared_tool tool_choice assistant_tool_call tool_result caller_metadata inferred)
                 )

  def normalize(request) when is_map(request) do
    request
    |> metadata_tool_context()
    |> case do
      nil -> inferred_context(request)
      context -> normalize_metadata_context(context)
    end
  end

  def normalize(_request), do: nil

  defp metadata_tool_context(request) do
    case Map.get(request, @metadata_key) do
      %{} = metadata ->
        case Map.get(metadata, @tool_context_key) do
          %{} = context -> context
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp normalize_metadata_context(context) do
    %{
      @schema_key => @schema,
      @phase_key => enum_value(Map.get(context, @phase_key), @phase_values, @phase_unknown),
      @primary_tool_key =>
        context
        |> Map.get(@primary_tool_key)
        |> normalize_tool_identity(@source_caller_metadata),
      @tool_call_id_key => text_value(Map.get(context, @tool_call_id_key)),
      @available_tools_key =>
        context
        |> Map.get(@available_tools_key, [])
        |> normalize_tool_list("caller_metadata"),
      @argument_hash_key => text_value(Map.get(context, @argument_hash_key)),
      @result_hash_key => text_value(Map.get(context, @result_hash_key)),
      @result_status_key =>
        enum_value(Map.get(context, @result_status_key), @result_status_values, nil),
      @confidence_key =>
        enum_value(Map.get(context, @confidence_key), @confidence_values, @confidence_declared)
    }
    |> compact()
  end

  defp inferred_context(request) do
    available_tools = request |> Map.get(@tools_key, []) |> normalize_declared_tools()
    chosen_tool = tool_choice_identity(request)
    assistant_tool = assistant_tool_call_identity(request)
    tool_result? = tool_result_message?(request)
    primary_tool = chosen_tool || assistant_tool || single_tool(available_tools)

    phase =
      cond do
        tool_result? -> @phase_result_interpretation
        primary_tool != nil or available_tools != [] -> @phase_planning
        true -> nil
      end

    if phase do
      %{
        @schema_key => @schema,
        @phase_key => phase,
        @primary_tool_key => primary_tool,
        @tool_call_id_key => tool_result_call_id(request) || assistant_tool_call_id(request),
        @available_tools_key => available_tools,
        @confidence_key =>
          inferred_confidence(chosen_tool, assistant_tool, available_tools, tool_result?)
      }
      |> compact()
    end
  end

  defp normalize_declared_tools(tools) when is_list(tools),
    do: normalize_tool_list(tools, @source_declared_tool)

  defp normalize_declared_tools(_tools), do: []

  defp normalize_tool_list(tools, source) when is_list(tools) do
    tools
    |> Enum.map(&normalize_tool_identity(&1, source))
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_tool_list(_tools, _source), do: []

  defp normalize_tool_identity(%{} = tool, source) do
    function = Map.get(tool, @function_key)

    name =
      [
        Map.get(tool, @name_key),
        function_name(function)
      ]
      |> first_text()

    namespace =
      tool
      |> Map.get(@namespace_key)
      |> text_value()
      |> case do
        nil -> default_namespace(tool)
        value -> value
      end

    if name do
      %{
        @namespace_key => namespace,
        @name_key => name,
        @source_key => enum_value(Map.get(tool, @source_key), @source_values, source),
        @risk_class_key =>
          enum_value(Map.get(tool, @risk_class_key), @risk_values, @risk_unknown),
        @schema_hash_key => text_value(Map.get(tool, @schema_hash_key))
      }
      |> compact()
    end
  end

  defp normalize_tool_identity(_tool, _source), do: nil

  defp tool_choice_identity(request) do
    case Map.get(request, @tool_choice_key) do
      %{} = choice ->
        choice
        |> normalize_tool_identity(@source_tool_choice)
        |> case do
          nil -> choice |> Map.get(@function_key) |> normalize_tool_identity(@source_tool_choice)
          identity -> identity
        end

      _ ->
        nil
    end
  end

  defp assistant_tool_call_identity(request) do
    request
    |> messages()
    |> Enum.find_value(fn message ->
      message
      |> Map.get(@tool_calls_key)
      |> case do
        [call | _] -> normalize_tool_identity(call, @source_assistant_tool_call)
        _ -> nil
      end
    end)
  end

  defp assistant_tool_call_id(request) do
    request
    |> messages()
    |> Enum.find_value(fn message ->
      message
      |> Map.get(@tool_calls_key)
      |> case do
        [%{} = call | _] -> text_value(Map.get(call, @id_key))
        _ -> nil
      end
    end)
  end

  defp tool_result_message?(request) do
    Enum.any?(messages(request), &(Map.get(&1, @role_key) == @tool_role))
  end

  defp tool_result_call_id(request) do
    request
    |> messages()
    |> Enum.find_value(fn message ->
      if Map.get(message, @role_key) == @tool_role,
        do: text_value(Map.get(message, @tool_call_id_key))
    end)
  end

  defp inferred_confidence(chosen_tool, assistant_tool, available_tools, tool_result?) do
    cond do
      chosen_tool != nil or assistant_tool != nil -> @confidence_exact
      tool_result? -> @confidence_inferred
      length(available_tools) == 1 -> @confidence_declared
      true -> @confidence_ambiguous
    end
  end

  defp single_tool([tool]), do: tool
  defp single_tool(_tools), do: nil

  defp default_namespace(%{@namespace_key => namespace}) when is_binary(namespace), do: namespace
  defp default_namespace(%{@type_key => "function"}), do: @namespace_openai_function
  defp default_namespace(_tool), do: @namespace_openai_tool

  defp messages(%{@messages_key => messages}) when is_list(messages),
    do: Enum.filter(messages, &is_map/1)

  defp messages(_request), do: []

  defp function_name(%{} = function), do: Map.get(function, @name_key)
  defp function_name(_function), do: nil

  defp first_text(values), do: Enum.find_value(values, &text_value/1)

  defp text_value(nil), do: nil

  defp text_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp text_value(value) when is_atom(value), do: value |> Atom.to_string() |> text_value()
  defp text_value(value) when is_integer(value), do: Integer.to_string(value)
  defp text_value(_value), do: nil

  defp enum_value(value, allowed, default) do
    value = text_value(value)
    if MapSet.member?(allowed, value), do: value, else: default
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, [], %{}] end)
    |> Map.new()
  end
end
