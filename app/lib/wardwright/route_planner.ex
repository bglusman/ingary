defmodule Wardwright.RoutePlanner do
  @moduledoc """
  Pure synthetic-model route planning.

  The planner keeps Calciforge's selector vocabulary explicit:

  * dispatchers choose the smallest eligible context window
  * cascades keep declaration-order fallback plans
  * alloys blend equivalent models by deterministic-all, weighted, or
    round-robin-style selection
  """

  alias Wardwright.Policy.CoreRuntime

  def select(config, estimated_prompt_tokens, attrs \\ %{}) when is_map(config) do
    targets =
      config
      |> Map.get("targets", [])
      |> filter_targets(Map.get(attrs, "allowed_targets"))
      |> target_index()

    forced_model = Map.get(attrs, "forced_model")

    decision =
      if forced_model in [nil, ""] do
        config
        |> root_selector()
        |> select_selector(config, targets, max(1, estimated_prompt_tokens), attrs)
      else
        select_forced_model(forced_model, config, targets, max(1, estimated_prompt_tokens), attrs)
      end

    decision
    |> Map.put(:estimated_prompt_tokens, max(1, estimated_prompt_tokens))
    |> Map.put(:policy_route_constraints, route_constraints(attrs))
  end

  def validate(config) when is_map(config) do
    targets = target_index(Map.get(config, "targets", []))

    with :ok <- validate_root(config),
         :ok <- validate_selectors("alloy", Map.get(config, "alloys", []), targets),
         :ok <- validate_selectors("cascade", Map.get(config, "cascades", []), targets),
         :ok <- validate_selectors("dispatcher", Map.get(config, "dispatchers", []), targets) do
      :ok
    end
  end

  defp root_selector(config) do
    root = Map.get(config, "route_root", "")
    first_dispatcher = first_selector_id(config, "dispatchers")
    first_cascade = first_selector_id(config, "cascades")
    first_alloy = first_selector_id(config, "alloys")

    CoreRuntime.dispatch(
      :route_default_root,
      fn ->
        :wardwright@route_core.default_root(root, first_dispatcher, first_cascade, first_alloy)
      end,
      fn ->
        cond do
          root != "" -> root
          first_dispatcher != "" -> first_dispatcher
          first_cascade != "" -> first_cascade
          first_alloy != "" -> first_alloy
          true -> "__targets_dispatcher__"
        end
      end
    )
  end

  defp select_selector("__targets_dispatcher__", config, targets, estimated, _attrs) do
    dispatcher = %{
      "id" => "dispatcher.prompt_length",
      "models" => config |> Map.get("targets", []) |> Enum.map(& &1["model"])
    }

    select_dispatcher(dispatcher, targets, estimated)
  end

  defp select_selector(root, config, targets, estimated, attrs) do
    cond do
      selector = find_selector(config, "dispatchers", root) ->
        select_dispatcher(selector, targets, estimated)

      selector = find_selector(config, "cascades", root) ->
        select_cascade(selector, targets, estimated)

      selector = find_selector(config, "alloys", root) ->
        select_alloy(selector, targets, estimated, attrs)

      true ->
        select_dispatcher(%{"id" => root, "models" => Map.keys(targets)}, targets, estimated)
        |> Map.merge(%{reason: "route root #{inspect(root)} was not configured"})
    end
  end

  defp select_dispatcher(dispatcher, targets, estimated) do
    {eligible, skipped} =
      dispatcher
      |> models_for(targets, "models")
      |> Enum.sort_by(fn model -> {model["context_window"], model["model"]} end)
      |> split_by_context(estimated)

    selected = List.first(eligible) || largest_known_model(targets)
    selected_models = selected_models(selected, eligible)

    decision(selected, %{
      route_type: "dispatcher",
      route_id: dispatcher["id"],
      combine_strategy: "smallest_context_window",
      selected_models: selected_models,
      fallback_models: Enum.drop(selected_models, 1),
      skipped: skipped,
      reason: dispatcher_reason(skipped, selected),
      rule: "select the smallest configured context window that fits the estimated prompt"
    })
  end

  defp select_forced_model(model, config, targets, estimated, attrs) do
    forced = Map.get(targets, model)
    skipped = targets |> Map.delete(model) |> Map.values() |> Enum.map(&policy_skip/1)

    {selected, skipped, reason} =
      cond do
        forced == nil ->
          {nil, skipped, forced_model_reason(false, false)}

        forced["context_window"] < estimated ->
          {nil, [context_skip(forced, estimated) | skipped], forced_model_reason(true, false)}

        true ->
          {forced, skipped, forced_model_reason(true, true)}
      end

    if selected == nil and Map.get(attrs, "allow_fallback") == true do
      select_forced_fallback(
        config,
        targets,
        estimated,
        attrs,
        forced_failure_skips(model, forced, estimated),
        reason
      )
    else
      selected_models = selected_models(selected, if(selected, do: [selected], else: []))

      decision(selected, %{
        route_type: "policy_override",
        route_id: "policy.forced_model",
        combine_strategy: "policy_forced_model",
        selected_models: selected_models,
        fallback_models: [],
        skipped: skipped,
        fallback_used: false,
        reason: reason,
        rule: "apply policy route override before provider selection"
      })
    end
  end

  defp select_forced_fallback(config, targets, estimated, attrs, forced_skipped, forced_reason) do
    fallback =
      config
      |> root_selector()
      |> select_selector(config, targets, estimated, Map.delete(attrs, "forced_model"))

    fallback
    |> Map.put(:route_type, "policy_override_fallback")
    |> Map.put(:route_id, "policy.forced_model")
    |> Map.put(:combine_strategy, "policy_forced_model_with_explicit_fallback")
    |> Map.put(:fallback_used, true)
    |> Map.put(:skipped, forced_skipped ++ Map.get(fallback, :skipped, []))
    |> Map.put(:reason, forced_fallback_reason(forced_reason))
    |> Map.put(:rule, "apply policy route override, then fall back only when allowed")
  end

  defp forced_failure_skips(model, nil, _estimated) do
    [%{"target" => model, "reason" => "forced_model_unavailable"}]
  end

  defp forced_failure_skips(_model, forced, estimated), do: [context_skip(forced, estimated)]

  defp select_cascade(cascade, targets, estimated) do
    {eligible, skipped} =
      cascade
      |> models_for(targets, "models")
      |> split_by_context(estimated)

    selected = List.first(eligible) || largest_known_model(targets)
    selected_models = selected_models(selected, eligible)

    decision(selected, %{
      route_type: "cascade",
      route_id: cascade["id"],
      combine_strategy: "ordered_fallback",
      selected_models: selected_models,
      fallback_models: Enum.drop(selected_models, 1),
      skipped: skipped,
      reason: cascade_reason(skipped, selected),
      rule: "try configured models in order, skipping models whose context window cannot fit"
    })
  end

  defp select_alloy(alloy, targets, estimated, attrs) do
    models = models_for(alloy, targets, "constituents")
    partial_context = Map.get(alloy, "partial_context", false)

    {eligible, skipped} =
      if partial_context do
        split_by_context(models, estimated)
      else
        min_context = alloy_min_context(alloy, models)

        if estimated <= min_context do
          {models, []}
        else
          {[], context_skips(models, estimated)}
        end
      end

    {ordered, strategy} = alloy_order(alloy, eligible, attrs, estimated)

    selected =
      List.first(ordered) || fallback_model(alloy, targets) || largest_known_model(targets)

    selected_models = selected_models(selected, ordered)

    decision(selected, %{
      route_type: "alloy",
      route_id: alloy["id"],
      combine_strategy: strategy,
      selected_models: selected_models,
      fallback_models: Enum.drop(selected_models, 1),
      skipped: skipped,
      fallback_used: eligible == [],
      reason: alloy_reason(partial_context, skipped, selected_models),
      rule: "blend eligible alloy constituents while respecting declared context windows"
    })
  end

  defp alloy_order(alloy, [], _attrs, _estimated),
    do: {[], normalize_alloy_strategy(Map.get(alloy, "strategy", "weighted"))}

  defp alloy_order(alloy, eligible, attrs, estimated) do
    strategy = normalize_alloy_strategy(Map.get(alloy, "strategy", "weighted"))

    ordered =
      case strategy do
        "deterministic_all" ->
          eligible

        "round_robin" ->
          rotate_by_seed(eligible, route_seed(attrs, estimated))

        "weighted" ->
          weighted_without_replacement(eligible, route_seed(attrs, estimated))
      end

    {ordered, strategy}
  end

  defp normalize_alloy_strategy(strategy) do
    strategy = string_value(strategy)

    CoreRuntime.dispatch(
      :route_alloy_strategy,
      fn -> :wardwright@route_core.normalize_alloy_strategy(strategy) end,
      fn ->
        case strategy do
          strategy when strategy in ["deterministic_all", "weighted", "round_robin"] -> strategy
          "all" -> "deterministic_all"
          _ -> "weighted"
        end
      end
    )
  end

  defp weighted_without_replacement(models, seed) do
    {ordered, _seed} =
      Enum.reduce(1..length(models), {[], models}, fn _, {ordered, remaining} ->
        total_weight = Enum.reduce(remaining, 0, fn model, acc -> acc + model_weight(model) end)
        total_weight = max(1, total_weight)
        selected_offset = :erlang.phash2({seed, Enum.map(remaining, & &1["model"])}, total_weight)
        {selected, next_remaining} = pop_weighted(remaining, selected_offset)
        {[selected | ordered], next_remaining}
      end)

    Enum.reverse(ordered)
  end

  defp pop_weighted(models, selected_offset) do
    {selected, remaining, _running} =
      Enum.reduce(models, {nil, [], 0}, fn model, {selected, remaining, running} ->
        weight = model_weight(model)

        cond do
          selected != nil ->
            {selected, [model | remaining], running}

          selected_offset < running + weight ->
            {model, remaining, running + weight}

          true ->
            {nil, [model | remaining], running + weight}
        end
      end)

    {selected || List.first(models), Enum.reverse(remaining)}
  end

  defp rotate_by_seed(models, seed) do
    offset = :erlang.phash2(seed, length(models))
    {left, right} = Enum.split(models, offset)
    right ++ left
  end

  defp route_seed(attrs, estimated) do
    Map.get(attrs, "route_seed") ||
      Map.get(attrs, "client_request_id") ||
      Map.get(attrs, "session_id") ||
      estimated
  end

  defp model_weight(model), do: integer_value(Map.get(model, "weight")) || 1

  defp split_by_context(models, estimated) do
    Enum.reduce(models, {[], []}, fn model, {eligible, skipped} ->
      if model["context_window"] >= estimated do
        {[model | eligible], skipped}
      else
        {eligible, [context_skip(model, estimated) | skipped]}
      end
    end)
    |> then(fn {eligible, skipped} -> {Enum.reverse(eligible), Enum.reverse(skipped)} end)
  end

  defp context_skips(models, estimated), do: Enum.map(models, &context_skip(&1, estimated))

  defp context_skip(model, estimated) do
    %{
      "target" => model["model"],
      "reason" => "context_window_too_small",
      "context_window" => model["context_window"],
      "estimated_prompt_tokens" => estimated
    }
  end

  defp policy_skip(model) do
    %{
      "target" => model["model"],
      "reason" => "policy_route_gate",
      "context_window" => model["context_window"]
    }
  end

  defp selected_models(nil, eligible), do: Enum.map(eligible, & &1["model"])
  defp selected_models(selected, []), do: [selected["model"]]
  defp selected_models(_selected, eligible), do: Enum.map(eligible, & &1["model"])

  defp decision(selected, attrs) do
    selected_model = if selected, do: selected["model"], else: "unconfigured/no-target"
    selected_context_window = if selected, do: selected["context_window"]

    attrs
    |> Map.put(:selected_model, selected_model)
    |> Map.put(:selected_context_window, selected_context_window)
    |> Map.put(:selected_provider, provider_from_model(selected_model))
    |> Map.put_new(:fallback_used, false)
    |> Map.put(:route_blocked, selected == nil)
  end

  defp dispatcher_reason(skipped, _selected) do
    skipped_count = length(skipped)

    CoreRuntime.dispatch(
      :route_dispatcher_reason,
      fn -> :wardwright@route_core.dispatcher_reason(skipped_count) end,
      fn ->
        case skipped_count do
          0 -> "estimated prompt fits selected context window"
          _ -> "estimated prompt exceeded smaller configured context windows"
        end
      end
    )
  end

  defp cascade_reason(skipped, _selected) do
    skipped_count = length(skipped)

    CoreRuntime.dispatch(
      :route_cascade_reason,
      fn -> :wardwright@route_core.cascade_reason(skipped_count) end,
      fn ->
        case skipped_count do
          0 -> "selected first configured cascade target"
          _ -> "cascade skipped targets whose context windows were too small"
        end
      end
    )
  end

  defp alloy_reason(partial_context, skipped, _selected_models) do
    skipped_count = length(skipped)

    CoreRuntime.dispatch(
      :route_alloy_reason,
      fn -> :wardwright@route_core.alloy_reason(partial_context, skipped_count) end,
      fn ->
        case {partial_context, skipped_count} do
          {true, 0} ->
            "partial alloy selected all constituents whose context windows fit"

          {true, _} ->
            "partial alloy dropped smaller constituents whose context windows were too small"

          {false, 0} ->
            "alloy constituents share a compatible context window for this prompt"

          {false, _} ->
            "alloy prompt exceeded the compatible minimum context window"
        end
      end
    )
  end

  defp alloy_min_context(alloy, models) do
    Map.get(alloy, "min_context_window") ||
      models |> Enum.map(& &1["context_window"]) |> Enum.min(fn -> 0 end)
  end

  defp fallback_model(selector, targets) do
    fallback = Map.get(selector, "fallback_model", "")
    if fallback == "", do: nil, else: Map.get(targets, fallback)
  end

  defp largest_known_model(targets) do
    targets
    |> Map.values()
    |> Enum.sort_by(fn target -> {target["context_window"], target["model"]} end)
    |> List.last()
  end

  defp target_index(targets) do
    Map.new(targets, fn target -> {target["model"], target} end)
  end

  defp filter_targets(targets, allowed_targets) when is_list(allowed_targets) do
    allowed_targets =
      allowed_targets
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if allowed_targets == [] do
      targets
    else
      Enum.filter(targets, &target_allowed?(&1, allowed_targets))
    end
  end

  defp filter_targets(targets, _allowed_targets), do: targets

  defp target_allowed?(target, allowed_targets) do
    model = target["model"]
    provider = model |> String.split("/", parts: 2) |> List.first()

    Enum.any?(allowed_targets, fn allowed ->
      allowed == model or allowed == provider or String.starts_with?(model, allowed <> "/")
    end)
  end

  defp route_constraints(attrs) do
    %{
      "allowed_targets" => Map.get(attrs, "allowed_targets"),
      "forced_model" => Map.get(attrs, "forced_model"),
      "allow_fallback" => Map.get(attrs, "allow_fallback")
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], false] end)
    |> Map.new()
  end

  defp models_for(selector, targets, key) do
    selector
    |> Map.get(key, Map.get(selector, "targets", []))
    |> Enum.map(&model_ref(&1, targets))
    |> Enum.reject(&is_nil/1)
  end

  defp model_ref(model, targets) when is_binary(model), do: Map.get(targets, model)

  defp model_ref(model, targets) when is_map(model) do
    target = Map.get(targets, model["model"], %{})
    Map.merge(target, model)
  end

  defp model_ref(_model, _targets), do: nil

  defp find_selector(config, key, id) do
    config
    |> Map.get(key, [])
    |> Enum.find(fn selector -> selector["id"] == id end)
  end

  defp validate_selectors(kind, selectors, targets) do
    Enum.reduce_while(selectors, MapSet.new(), fn selector, seen ->
      id = Map.get(selector, "id", "")

      cond do
        id == "" ->
          {:halt, {:error, "#{kind} id must not be empty"}}

        MapSet.member?(seen, id) ->
          {:halt, {:error, "duplicate #{kind} #{id}"}}

        true ->
          case validate_selector_models(kind, selector, targets) do
            :ok -> {:cont, MapSet.put(seen, id)}
            error -> {:halt, error}
          end
      end
    end)
    |> case do
      %MapSet{} -> :ok
      other -> other
    end
  end

  defp validate_root(config) do
    root = Map.get(config, "route_root", "")

    selector_ids =
      ["alloys", "cascades", "dispatchers"]
      |> Enum.flat_map(fn key -> Enum.map(Map.get(config, key, []), & &1["id"]) end)

    cond do
      root in ["", "__targets_dispatcher__"] ->
        :ok

      root == "dispatcher.prompt_length" and Map.get(config, "dispatchers", []) == [] ->
        :ok

      root in selector_ids ->
        :ok

      true ->
        {:error, "route_root #{root} does not match a configured selector"}
    end
  end

  defp validate_selector_models("alloy", selector, targets) do
    with :ok <- validate_model_references("alloy", selector, targets, "constituents") do
      validate_alloy_models(selector, targets)
    end
  end

  defp validate_selector_models(kind, selector, targets) do
    with :ok <- validate_model_references(kind, selector, targets, "models") do
      validate_ordered_selector_models(kind, selector, targets)
    end
  end

  defp validate_model_references(kind, selector, targets, key) do
    selector
    |> Map.get(key, Map.get(selector, "targets", []))
    |> Enum.find(fn
      model when is_binary(model) -> not Map.has_key?(targets, model)
      _model -> false
    end)
    |> case do
      nil -> :ok
      model -> {:error, "#{kind} #{selector["id"]} references unknown target #{model}"}
    end
  end

  defp validate_alloy_models(selector, targets) do
    models = models_for(selector, targets, "constituents")

    cond do
      length(models) < 2 ->
        {:error, "alloy #{selector["id"]} must define at least 2 constituents"}

      invalid_model = Enum.find(models, &invalid_model?/1) ->
        {:error,
         "alloy #{selector["id"]} target #{invalid_model["model"]} context_window must be positive"}

      invalid_weight = Enum.find(models, &(model_weight(&1) <= 0)) ->
        {:error,
         "alloy #{selector["id"]} target #{invalid_weight["model"]} weight must be positive"}

      not valid_alloy_strategy?(Map.get(selector, "strategy", "weighted")) ->
        {:error,
         "alloy #{selector["id"]} strategy must be weighted, round_robin, or deterministic_all"}

      true ->
        :ok
    end
  end

  defp validate_ordered_selector_models(kind, selector, targets) do
    models = models_for(selector, targets, "models")

    cond do
      models == [] ->
        {:error, "#{kind} #{selector["id"]} must define at least 1 model"}

      invalid_model = Enum.find(models, &invalid_model?/1) ->
        {:error,
         "#{kind} #{selector["id"]} target #{invalid_model["model"]} context_window must be positive"}

      true ->
        :ok
    end
  end

  defp invalid_model?(model),
    do:
      model["model"] in [nil, ""] or not is_integer(model["context_window"]) or
        model["context_window"] <= 0

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp integer_value(_), do: nil

  defp forced_model_reason(available?, fits_prompt?) do
    CoreRuntime.dispatch(
      :route_forced_model_reason,
      fn -> :wardwright@route_core.forced_model_reason(available?, fits_prompt?) end,
      fn ->
        case {available?, fits_prompt?} do
          {false, _} -> "policy forced model was not in the allowed route set"
          {true, false} -> "policy forced model was too small for estimated prompt"
          {true, true} -> "policy forced selected model"
        end
      end
    )
  end

  defp forced_fallback_reason(forced_reason) do
    CoreRuntime.dispatch(
      :route_forced_fallback_reason,
      fn -> :wardwright@route_core.forced_fallback_reason(forced_reason) end,
      fn -> "#{forced_reason}; explicit policy fallback allowed" end
    )
  end

  defp provider_from_model(model) do
    model |> String.split("/", parts: 2) |> List.first()
  end

  defp valid_alloy_strategy?(strategy) do
    strategy = string_value(strategy)

    CoreRuntime.dispatch(
      :route_valid_alloy_strategy,
      fn -> :wardwright@route_core.validate_strategy(strategy) end,
      fn -> strategy in ["weighted", "round_robin", "deterministic_all", "all"] end
    )
  end

  defp first_selector_id(config, key) do
    case Map.get(config, key, []) do
      [%{"id" => id} | _rest] when is_binary(id) -> id
      _selectors -> ""
    end
  end

  defp string_value(value) when is_binary(value), do: value
  defp string_value(_value), do: ""
end
