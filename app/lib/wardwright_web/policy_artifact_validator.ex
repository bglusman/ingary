defmodule WardwrightWeb.PolicyArtifactValidator do
  @moduledoc false

  @supported_engines MapSet.new(["primitive", "dune", "wasm", "hybrid"])
  @supported_rule_kinds MapSet.new([
                          "request_guard",
                          "request_transform",
                          "receipt_annotation",
                          "route_gate",
                          "history_threshold",
                          "history_regex_threshold"
                        ])
  @supported_stream_actions MapSet.new([
                              "pass",
                              "block",
                              "rewrite_chunk",
                              "retry_with_reminder"
                            ])
  @terminal_metadata_gap "provider terminal metadata is not yet preserved in receipts"

  def validate(nil), do: validate(Wardwright.current_config(), source: "current_config")

  def validate(artifact) when is_map(artifact), do: validate(artifact, source: "submitted")

  def validate(_artifact) do
    result("submitted", error([], "artifact", "artifact must be a JSON object"))
  end

  def validate(artifact, opts) when is_map(artifact) do
    source = Keyword.get(opts, :source, "submitted")

    checks =
      []
      |> validate_synthetic_model(artifact)
      |> validate_targets(artifact)
      |> validate_routes(artifact)
      |> validate_governance(artifact)
      |> validate_stream_rules(artifact)
      |> validate_structured_output(artifact)
      |> validate_provider_capabilities(artifact)
      |> add_simulation_coverage_gap(artifact)

    result(source, checks)
  end

  defp validate_synthetic_model(checks, artifact) do
    synthetic_model = artifact |> Map.get("synthetic_model", "") |> to_string() |> String.trim()

    cond do
      synthetic_model == "" ->
        error(checks, "synthetic_model", "synthetic_model must not be empty")

      String.contains?(synthetic_model, "/") ->
        error(checks, "synthetic_model", "synthetic_model must be unprefixed")

      true ->
        checks
    end
  end

  defp validate_targets(checks, artifact) do
    case Map.get(artifact, "targets") do
      targets when is_list(targets) and targets != [] ->
        {checks, _seen} =
          Enum.reduce(targets, {checks, MapSet.new()}, fn target, {checks, seen} ->
            validate_target(checks, seen, target)
          end)

        checks

      _other ->
        error(checks, "targets", "targets must be a non-empty list")
    end
  end

  defp validate_target(checks, seen, target) when is_map(target) do
    model = target |> Map.get("model", "") |> to_string() |> String.trim()
    context_window = Map.get(target, "context_window")

    checks =
      cond do
        model == "" ->
          error(checks, "targets[].model", "target model must not be empty")

        MapSet.member?(seen, model) ->
          error(checks, "targets", "duplicate target #{model}")

        true ->
          checks
      end

    checks =
      if positive_integer?(context_window) do
        checks
      else
        error(
          checks,
          "targets[].context_window",
          "target #{model} context_window must be positive"
        )
      end

    {checks, MapSet.put(seen, model)}
  end

  defp validate_target(checks, seen, _target) do
    {error(checks, "targets", "target entries must be objects"), seen}
  end

  defp validate_routes(checks, artifact) do
    checks = validate_selector_collections(checks, artifact)
    targets = target_models(artifact)
    selectors = selectors(artifact)
    route_root = artifact |> Map.get("route_root", "dispatcher.prompt_length") |> to_string()
    selector_ids = selectors |> Enum.map(&Map.get(&1, "id")) |> MapSet.new()

    checks =
      if MapSet.member?(selector_ids, route_root) do
        checks
      else
        error(
          checks,
          "route_root",
          "route_root #{inspect(route_root)} does not reference a selector"
        )
      end

    Enum.reduce(selectors, checks, fn selector, checks ->
      selector_targets(selector)
      |> Enum.reduce(checks, fn model, checks ->
        if MapSet.member?(targets, model) do
          checks
        else
          error(
            checks,
            "route_graph",
            "selector #{selector["id"]} references unknown target #{model}"
          )
        end
      end)
    end)
  end

  defp validate_selector_collections(checks, artifact) do
    ["dispatchers", "cascades", "alloys"]
    |> Enum.reduce(checks, fn field, checks ->
      validate_selector_collection(checks, field, Map.get(artifact, field, []))
    end)
  end

  defp validate_selector_collection(checks, _field, []), do: checks

  defp validate_selector_collection(checks, field, selectors) when is_list(selectors) do
    Enum.reduce(selectors, checks, fn
      selector, checks when is_map(selector) ->
        validate_selector(checks, field, selector)

      _selector, checks ->
        error(checks, field, "#{field} entries must be objects")
    end)
  end

  defp validate_selector_collection(checks, field, _selectors) do
    error(checks, field, "#{field} must be a list")
  end

  defp validate_selector(checks, field, selector) do
    selector_id = selector |> Map.get("id", "") |> to_string() |> String.trim()

    checks =
      if selector_id == "" do
        error(checks, "#{field}[].id", "#{field} selector id must not be empty")
      else
        checks
      end

    if selector_targets_raw(selector) |> is_list() do
      checks
    else
      error(checks, field, "#{field} selector #{selector_id} targets must be a list")
    end
  end

  defp validate_governance(checks, artifact) do
    case Map.get(artifact, "governance", []) do
      rules when is_list(rules) ->
        Enum.reduce(rules, checks, &validate_governance_rule(&1, &2, artifact))

      _other ->
        error(checks, "governance", "governance must be a list")
    end
  end

  defp validate_governance_rule(rule, checks, artifact) when is_map(rule) do
    rule_id = rule |> Map.get("id", "policy") |> to_string()
    engine = blank_to_nil(Map.get(rule, "engine"))
    kind = rule |> Map.get("kind", "") |> to_string()

    checks =
      cond do
        engine != nil and not MapSet.member?(@supported_engines, engine) ->
          error(checks, "governance.engine", "rule #{rule_id} uses unsupported engine #{engine}")

        engine != nil ->
          opaque(
            checks,
            "governance",
            rule_id,
            "sandboxed engine #{engine} requires scenario coverage"
          )

        kind == "" ->
          warning(checks, "governance.kind", "rule #{rule_id} has no kind")

        not MapSet.member?(@supported_rule_kinds, kind) ->
          warning(
            checks,
            "governance.kind",
            "rule #{rule_id} uses currently ignored kind #{kind}"
          )

        true ->
          checks
      end

    validate_route_action(rule, checks, artifact)
  end

  defp validate_governance_rule(_rule, checks, _artifact) do
    error(checks, "governance", "governance rules must be objects")
  end

  defp validate_route_action(rule, checks, artifact) do
    case Map.get(rule, "action") do
      action when action in ["restrict_routes", "switch_model", "reroute"] ->
        allowed = route_action_targets(rule)
        known = target_models(artifact)

        Enum.reduce(allowed, checks, fn model, checks ->
          if MapSet.member?(known, model) do
            checks
          else
            error(
              checks,
              "governance.allowed_targets",
              "route action references unknown target #{model}"
            )
          end
        end)

      _other ->
        checks
    end
  end

  defp validate_stream_rules(checks, artifact) do
    case Map.get(artifact, "stream_rules", []) do
      rules when is_list(rules) ->
        Enum.reduce(rules, checks, &validate_stream_rule/2)

      _other ->
        error(checks, "stream_rules", "stream_rules must be a list")
    end
  end

  defp validate_stream_rule(rule, checks) when is_map(rule) do
    action = rule |> Map.get("action", "pass") |> to_string()
    rule_id = rule |> Map.get("id", "stream-rule") |> to_string()

    checks =
      if MapSet.member?(@supported_stream_actions, action) do
        checks
      else
        error(
          checks,
          "stream_rules.action",
          "stream rule #{rule_id} uses unsupported action #{action}"
        )
      end

    if action in ["block", "rewrite_chunk", "retry_with_reminder"] and
         blank_to_nil(Map.get(rule, "pattern")) == nil do
      error(checks, "stream_rules.pattern", "stream rule #{rule_id} needs a pattern")
    else
      checks
    end
  end

  defp validate_stream_rule(_rule, checks) do
    error(checks, "stream_rules", "stream rules must be objects")
  end

  defp validate_structured_output(checks, artifact) do
    case Map.get(artifact, "structured_output") do
      nil ->
        checks

      %{"schemas" => schemas} when is_map(schemas) and map_size(schemas) > 0 ->
        checks

      %{} ->
        error(checks, "structured_output.schemas", "structured_output requires non-empty schemas")

      _other ->
        error(checks, "structured_output", "structured_output must be an object")
    end
  end

  defp validate_provider_capabilities(checks, artifact) do
    artifact
    |> list_field("targets")
    |> Enum.reduce(checks, fn
      %{"model" => model} = target, checks when is_binary(model) ->
        provider_kind = provider_kind(model, target)

        checks =
          if provider_kind in ["openai-compatible", "ollama"] do
            capability_gap(checks, model, "terminal_metadata", @terminal_metadata_gap)
          else
            checks
          end

        if provider_kind == "openai-compatible" and
             blank_to_nil(Map.get(target, "provider_base_url")) == nil do
          error(checks, "targets[].provider_base_url", "#{model} requires provider_base_url")
        else
          checks
        end

      _target, checks ->
        checks
    end)
  end

  defp add_simulation_coverage_gap(checks, artifact) do
    if list_field(artifact, "scenarios") == [] do
      coverage_gap(
        checks,
        "scenarios",
        "no persisted scenario records are attached; validation cannot prove behavior coverage"
      )
    else
      checks
    end
  end

  defp result(source, checks) do
    errors = entries(checks, :error)
    warnings = entries(checks, :warning)
    opaque_regions = entries(checks, :opaque_region)
    provider_gaps = entries(checks, :provider_capability_gap)
    coverage_gaps = entries(checks, :coverage_gap)

    %{
      "schema" => "wardwright.policy_validation.v1",
      "source" => source,
      "verdict" => verdict(errors, opaque_regions, provider_gaps, coverage_gaps),
      "errors" => errors,
      "warnings" => warnings,
      "opaque_regions" => opaque_regions,
      "provider_capability_gaps" => provider_gaps,
      "coverage_gaps" => coverage_gaps,
      "limits" => [
        "validation is structural and capability-oriented; it does not execute live providers",
        "sandboxed engines require scenario evidence before they can be treated as reviewed",
        "fixture-backed simulations are acceptable only when their source is explicit"
      ]
    }
  end

  defp verdict([], [], [], []), do: "valid"
  defp verdict([], _opaque_regions, _provider_gaps, _coverage_gaps), do: "needs_review"
  defp verdict(_errors, _opaque_regions, _provider_gaps, _coverage_gaps), do: "invalid"

  defp error(checks, path, message), do: [{:error, path, message} | checks]
  defp warning(checks, path, message), do: [{:warning, path, message} | checks]

  defp opaque(checks, path, rule_id, message) do
    [{:opaque_region, path, %{"rule_id" => rule_id, "message" => message}} | checks]
  end

  defp capability_gap(checks, model, capability, message) do
    [
      {:provider_capability_gap, "targets",
       %{"model" => model, "capability" => capability, "message" => message}}
      | checks
    ]
  end

  defp coverage_gap(checks, path, message), do: [{:coverage_gap, path, message} | checks]

  defp entries(checks, type) do
    checks
    |> Enum.reverse()
    |> Enum.filter(fn {entry_type, _path, _message} -> entry_type == type end)
    |> Enum.map(fn
      {_type, _path, message} when is_map(message) ->
        message

      {_type, path, message} ->
        %{"path" => path, "message" => message}
    end)
  end

  defp selectors(artifact) do
    selectors =
      [
        list_field(artifact, "dispatchers"),
        list_field(artifact, "cascades"),
        list_field(artifact, "alloys")
      ]
      |> List.flatten()
      |> Enum.filter(&is_map/1)

    case selectors do
      [] ->
        [
          %{
            "id" => Map.get(artifact, "route_root", "dispatcher.prompt_length"),
            "models" => artifact |> target_models() |> MapSet.to_list()
          }
        ]

      configured ->
        configured
    end
  end

  defp selector_targets(selector) do
    selector
    |> selector_targets_raw()
    |> list_value()
    |> Enum.map(fn
      model when is_binary(model) -> model
      %{"model" => model} when is_binary(model) -> model
      other -> to_string(other)
    end)
  end

  defp selector_targets_raw(selector) do
    Map.get(
      selector,
      "models",
      Map.get(selector, "constituents", Map.get(selector, "targets", []))
    )
  end

  defp target_models(artifact) do
    artifact
    |> list_field("targets")
    |> Enum.flat_map(fn
      %{"model" => model} when is_binary(model) -> [model]
      _target -> []
    end)
    |> MapSet.new()
  end

  defp route_action_targets(rule) do
    rule
    |> Map.get("allowed_targets", List.wrap(Map.get(rule, "target_model", [])))
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp list_field(map, key) do
    case Map.get(map, key, []) do
      value when is_list(value) -> value
      _other -> []
    end
  end

  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp provider_kind(model, target) do
    cond do
      blank_to_nil(Map.get(target, "provider_kind")) != nil -> target["provider_kind"]
      String.starts_with?(model, "ollama/") -> "ollama"
      true -> "mock"
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil
end
