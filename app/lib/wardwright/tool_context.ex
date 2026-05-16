defmodule Wardwright.ToolContext do
  @moduledoc """
  Boundary normalizer for tool context facts carried by model requests.

  The normalized map is receipt evidence only for now. Policy selectors and
  counters can depend on this shape once the tool-policy contract stabilizes.
  """

  @schema "wardwright.tool_context.v1"
  @argument_hash_key "argument_hash"
  @arguments_key "arguments"
  @available_tools_key "available_tools"
  @confidence_key "confidence"
  @content_key "content"
  @function_key "function"
  @metadata_key "metadata"
  @id_key "id"
  @messages_key "messages"
  @name_key "name"
  @namespace_key "namespace"
  @phase_key "phase"
  @primary_tool_key "primary_tool"
  @parameters_key "parameters"
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

  @confidence_declared "declared"
  @phase_unknown "unknown"
  @risk_unknown "unknown"
  @source_assistant_tool_call "assistant_tool_call"
  @source_caller_metadata "caller_metadata"
  @source_declared_tool "declared_tool"
  @source_tool_choice "tool_choice"

  @hash_prefix "sha256:"

  @confidence_values MapSet.new(~w(exact declared inferred ambiguous))
  @phase_values MapSet.new(
                  ~w(planning argument_repair result_interpretation loop_governance unknown)
                )
  @result_status_values MapSet.new(~w(success error timeout rejected unknown))
  @risk_values MapSet.new(~w(read_only write irreversible external_side_effect unknown))
  @source_values MapSet.new(
                   ~w(declared_tool tool_choice assistant_tool_call tool_result caller_metadata inferred)
                 )

  def normalize(request, opts \\ [])

  def normalize(request, opts) when is_map(request) do
    if Keyword.get(opts, :trusted_metadata, false) do
      request
      |> metadata_tool_context()
      |> case do
        nil -> inferred_context(request)
        context -> normalize_metadata_context(context)
      end
    else
      inferred_context(request)
    end
  end

  def normalize(_request, _opts), do: nil

  def normalize_request(request, opts \\ [])

  def normalize_request(request, opts) when is_map(request) do
    case normalize(request, opts) do
      nil ->
        {request, nil}

      tool_context ->
        metadata =
          request
          |> Map.get(@metadata_key, %{})
          |> case do
            metadata when is_map(metadata) -> metadata
            _metadata -> %{}
          end
          |> Map.put(@tool_context_key, tool_context)

        {Map.put(request, @metadata_key, metadata), tool_context}
    end
  end

  def normalize_request(request, _opts), do: {request, nil}

  def cache_key(%{
        @primary_tool_key => %{@namespace_key => namespace, @name_key => name},
        @phase_key => phase
      }) do
    [namespace, name, phase || @phase_unknown]
    |> Enum.map(&text_value/1)
    |> case do
      [namespace, name, phase] when namespace != nil and name != nil and phase != nil ->
        Enum.join([namespace, name, phase], ":")

      _parts ->
        nil
    end
  end

  def cache_key(_tool_context), do: nil

  def matches?(tool_context, matcher) when is_map(tool_context) and is_map(matcher) do
    tool = Map.get(tool_context, @primary_tool_key, %{})

    list_matches?(
      matcher_values(matcher, @phase_key, "phases"),
      Map.get(tool_context, @phase_key)
    ) and
      list_matches?(
        matcher_values(matcher, @namespace_key, "namespaces"),
        Map.get(tool, @namespace_key)
      ) and
      list_matches?(matcher_values(matcher, @name_key, "names"), Map.get(tool, @name_key)) and
      list_matches?(
        matcher_values(matcher, @risk_class_key, "risk_classes"),
        Map.get(tool, @risk_class_key)
      )
  end

  def matches?(_tool_context, _matcher), do: false

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
      @argument_hash_key => hash_value(Map.get(context, @argument_hash_key)),
      @result_hash_key => hash_value(Map.get(context, @result_hash_key)),
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
      inferred_phase(
        primary_tool != nil,
        available_tools != [],
        tool_result?
      )

    if phase do
      %{
        @schema_key => @schema,
        @phase_key => phase,
        @primary_tool_key => primary_tool,
        @tool_call_id_key => tool_result_call_id(request) || assistant_tool_call_id(request),
        @available_tools_key => available_tools,
        @argument_hash_key => assistant_tool_argument_hash(request),
        @result_hash_key => tool_result_hash(request),
        @result_status_key => result_status(tool_result?),
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
        @schema_hash_key => text_value(Map.get(tool, @schema_hash_key)) || schema_hash(function)
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

  defp assistant_tool_argument_hash(request) do
    request
    |> messages()
    |> Enum.find_value(fn message ->
      message
      |> Map.get(@tool_calls_key)
      |> case do
        [%{} = call | _] ->
          call
          |> Map.get(@function_key, %{})
          |> case do
            %{} = function -> content_hash(Map.get(function, @arguments_key))
            _function -> nil
          end

        _ ->
          nil
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

  defp tool_result_hash(request) do
    request
    |> messages()
    |> Enum.find_value(fn message ->
      if Map.get(message, @role_key) == @tool_role,
        do: content_hash(Map.get(message, @content_key))
    end)
  end

  defp result_status(tool_result?) do
    :wardwright@tool_context_core.result_status(tool_result?) |> blank_to_nil()
  end

  defp inferred_confidence(chosen_tool, assistant_tool, available_tools, tool_result?) do
    :wardwright@tool_context_core.inferred_confidence(
      chosen_tool != nil,
      assistant_tool != nil,
      length(available_tools),
      tool_result?
    )
  end

  defp single_tool([tool]), do: tool
  defp single_tool(_tools), do: nil

  defp default_namespace(%{@namespace_key => namespace}) when is_binary(namespace), do: namespace

  defp default_namespace(tool) do
    type = text_value(Map.get(tool, @type_key)) || ""
    :wardwright@tool_context_core.default_namespace(false, type)
  end

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

  defp matcher_values(matcher, singular_key, plural_key) do
    matcher
    |> Map.get(singular_key, Map.get(matcher, plural_key))
    |> case do
      values when is_list(values) -> values
      nil -> []
      value -> [value]
    end
    |> Enum.map(&text_value/1)
    |> Enum.reject(&is_nil/1)
  end

  defp list_matches?(expected, actual) do
    actual = text_value(actual) || ""
    :wardwright@tool_context_core.list_matches(expected, actual)
  end

  defp schema_hash(%{} = function), do: content_hash(Map.get(function, @parameters_key))
  defp schema_hash(_function), do: nil

  defp content_hash(nil), do: nil

  defp content_hash(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> @hash_prefix <> Base.encode16(:crypto.hash(:sha256, text), case: :lower)
    end
  end

  defp content_hash(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> content_hash(encoded)
      {:error, _error} -> nil
    end
  end

  defp hash_value(value) do
    case text_value(value) do
      @hash_prefix <> _rest = hash -> hash
      nil -> nil
      _text -> content_hash(value)
    end
  end

  defp enum_value(value, allowed, default) do
    value = text_value(value)
    if MapSet.member?(allowed, value), do: value, else: default
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, [], %{}] end)
    |> Map.new()
  end

  defp inferred_phase(has_primary_tool?, has_available_tools?, tool_result?) do
    :wardwright@tool_context_core.inferred_phase(
      has_primary_tool?,
      has_available_tools?,
      tool_result?
    )
    |> blank_to_nil()
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
