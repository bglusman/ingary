defmodule Wardwright.Policy.StructuredOutput do
  @moduledoc false

  def run(nil, provider_fun) when is_function(provider_fun, 1), do: provider_fun.(0)

  def run(%{} = config, provider_fun) when is_function(provider_fun, 1),
    do: guard_loop(config, provider_fun)

  def run(_config, provider_fun) when is_function(provider_fun, 1), do: provider_fun.(0)

  def validate_output(output, config) when is_binary(output) and is_map(config) do
    with {:ok, parsed} <- Jason.decode(output),
         {:ok, schema_id} <- select_schema(parsed, Map.get(config, "schemas", %{})),
         :ok <- validate_semantic_rules(parsed, Map.get(config, "semantic_rules", [])) do
      {:ok, schema_id, parsed}
    else
      {:error, %Jason.DecodeError{}} -> {:error, "json_syntax", "structured-json"}
      {:error, :schema} -> {:error, "schema_validation", "structured-json"}
      {:error, {:semantic, rule_id}} -> {:error, "semantic_validation", rule_id}
    end
  end

  def validate_output(_output, _config), do: {:error, "schema_validation", "structured-json"}

  defp guard_loop(config, provider_fun) do
    guard_config = Map.get(config, "guard_loop", %{})
    max_attempts = positive_integer(guard_config["max_attempts"], 3)
    max_failures_per_rule = positive_integer(guard_config["max_failures_per_rule"], max_attempts)

    0..(max_attempts - 1)
    |> Enum.reduce_while(%{"guard_events" => [], "rule_failures" => %{}}, fn attempt_index, acc ->
      provider = provider_fun.(attempt_index)

      if provider.status != "completed" do
        {:halt, Map.put(provider, :structured_output, exhausted(acc, provider.status))}
      else
        case validate_output(provider.content || "", config) do
          {:ok, schema_id, parsed} ->
            final_status =
              Wardwright.Policy.StructuredCore.success_status(length(acc["guard_events"]))

            structured = %{
              "final_status" => final_status,
              "selected_schema" => schema_id,
              "parsed_output" => parsed,
              "guard_events" => acc["guard_events"],
              "attempt_count" => attempt_index + 1
            }

            {:halt, %{provider | status: final_status, structured_output: structured}}

          {:error, guard_type, rule_id} ->
            failures = Map.update(acc["rule_failures"], rule_id, 1, &(&1 + 1))

            event = %{
              "type" => "structured_output.guard",
              "attempt_index" => attempt_index,
              "rule_id" => rule_id,
              "guard_type" => guard_type,
              "action" =>
                Map.get(
                  guard_config,
                  "on_violation",
                  Wardwright.Policy.StructuredCore.guard_action()
                )
            }

            acc = %{
              acc
              | "guard_events" => acc["guard_events"] ++ [event],
                "rule_failures" => failures
            }

            outcome_status =
              Wardwright.Policy.StructuredCore.loop_outcome_status(
                rule_id,
                failures[rule_id],
                max_failures_per_rule,
                attempt_index + 1,
                max_attempts
              )

            cond do
              outcome_status == "exhausted_rule_budget" ->
                {:halt,
                 %{
                   provider
                   | content: nil,
                     status: outcome_status,
                     structured_output: exhausted(acc, outcome_status, rule_id)
                 }}

              outcome_status == "exhausted_guard_budget" ->
                {:halt,
                 %{
                   provider
                   | content: nil,
                     status: outcome_status,
                     structured_output: exhausted(acc, outcome_status)
                 }}

              true ->
                {:cont, acc}
            end
        end
      end
    end)
  end

  defp exhausted(acc, status, exhausted_rule_id \\ nil) do
    %{
      "final_status" => status,
      "selected_schema" => nil,
      "parsed_output" => nil,
      "guard_events" => acc["guard_events"],
      "attempt_count" => length(acc["guard_events"])
    }
    |> put_if_present("exhausted_rule_id", exhausted_rule_id)
  end

  defp select_schema(parsed, schemas) when is_map(parsed) and is_map(schemas) do
    schemas
    |> Enum.find(fn {_schema_id, schema} -> schema_valid?(parsed, schema) end)
    |> case do
      {schema_id, _schema} -> {:ok, schema_id}
      nil -> {:error, :schema}
    end
  end

  defp select_schema(_parsed, _schemas), do: {:error, :schema}

  defp schema_valid?(parsed, %{"type" => "object"} = schema) do
    required = Map.get(schema, "required", [])
    properties = Map.get(schema, "properties", %{})
    allowed = MapSet.new(Map.keys(properties))

    required_ok? = Enum.all?(required, &Map.has_key?(parsed, &1))

    additional_ok? =
      schema["additionalProperties"] != false or
        MapSet.subset?(MapSet.new(Map.keys(parsed)), allowed)

    properties_ok? =
      Enum.all?(properties, fn {key, property_schema} ->
        not Map.has_key?(parsed, key) or property_valid?(parsed[key], property_schema)
      end)

    :wardwright@structured_validation_core.object_schema_valid(
      required_ok?,
      additional_ok?,
      properties_ok?
    )
  end

  defp schema_valid?(_parsed, _schema), do: false

  defp property_valid?(_value, nil), do: false

  defp property_valid?(value, %{"type" => "string"} = schema) do
    :wardwright@structured_validation_core.string_property_valid(
      is_binary(value),
      if(is_binary(value), do: String.length(value), else: 0),
      string_min_length(schema),
      enum_valid?(value, schema)
    )
  end

  defp property_valid?(value, %{"type" => "number"} = schema) do
    minimum = number_minimum(schema, value)
    maximum = number_maximum(schema, value)

    :wardwright@structured_validation_core.number_property_valid(
      is_number(value),
      is_number(value) and value >= minimum,
      is_number(value) and value <= maximum
    )
  end

  defp property_valid?(value, %{"type" => "array", "items" => %{"type" => "string"}}) do
    :wardwright@structured_validation_core.string_array_property_valid(
      is_list(value),
      is_list(value) and Enum.all?(value, &is_binary/1)
    )
  end

  defp property_valid?(_value, _schema), do: false

  defp enum_valid?(value, %{"enum" => allowed}), do: value in allowed
  defp enum_valid?(_value, _schema), do: true

  defp string_min_length(schema) do
    case Map.fetch(schema, "minLength") do
      {:ok, value} -> value
      :error -> 0
    end
  end

  defp number_minimum(schema, default) do
    case Map.fetch(schema, "minimum") do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp number_maximum(schema, default) do
    case Map.fetch(schema, "maximum") do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp semantic_pattern(rule) do
    case Map.fetch(rule, "pattern") do
      {:ok, value} -> to_string(value)
      :error -> ""
    end
  end

  defp validate_semantic_rules(parsed, rules) when is_list(rules) do
    Enum.reduce_while(rules, :ok, fn rule, :ok ->
      if semantic_rule_valid?(parsed, rule),
        do: {:cont, :ok},
        else: {:halt, {:error, {:semantic, rule["id"] || "semantic-rule"}}}
    end)
  end

  defp validate_semantic_rules(_parsed, _rules), do: :ok

  defp semantic_rule_valid?(parsed, %{"kind" => "json_path_number", "path" => path} = rule) do
    value = json_pointer(parsed, path)

    :wardwright@structured_validation_core.semantic_number_rule_valid(
      is_number(value),
      is_number(value) and compare_number(value, rule)
    )
  end

  defp semantic_rule_valid?(
         parsed,
         %{"kind" => "json_path_string_not_contains", "path" => path} = rule
       ) do
    case json_pointer(parsed, path) do
      value when is_binary(value) ->
        contains_pattern? =
          String.contains?(
            String.downcase(value),
            rule |> semantic_pattern() |> String.downcase()
          )

        :wardwright@structured_validation_core.semantic_string_not_contains_valid(
          true,
          contains_pattern?
        )

      _ ->
        :wardwright@structured_validation_core.semantic_string_not_contains_valid(
          false,
          false
        )
    end
  end

  defp semantic_rule_valid?(_parsed, _rule), do: true

  defp compare_number(value, rule) do
    Enum.all?(rule, fn
      {"gte", bound} when is_number(bound) -> value >= bound
      {"gt", bound} when is_number(bound) -> value > bound
      {"lte", bound} when is_number(bound) -> value <= bound
      {"lt", bound} when is_number(bound) -> value < bound
      {_key, _bound} -> true
    end)
  end

  defp json_pointer(parsed, "/" <> path) do
    path
    |> String.split("/")
    |> Enum.reduce(parsed, fn segment, acc ->
      if is_map(acc), do: Map.get(acc, segment), else: nil
    end)
  end

  defp json_pointer(_parsed, _path), do: nil

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default
end
