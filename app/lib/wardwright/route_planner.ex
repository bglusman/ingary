defmodule Wardwright.RoutePlanner do
  @moduledoc """
  Pure synthetic-model route planning.

  The planner keeps Calciforge's selector vocabulary explicit:

  * dispatchers choose the smallest eligible context window
  * cascades keep declaration-order fallback plans
  * alloys blend equivalent models by deterministic-all, weighted, or
    round-robin-style selection
  """

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
        select_forced_model(forced_model, targets, max(1, estimated_prompt_tokens))
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

    cond do
      root != "" -> root
      Map.get(config, "dispatchers", []) != [] -> config["dispatchers"] |> hd() |> Map.get("id")
      Map.get(config, "cascades", []) != [] -> config["cascades"] |> hd() |> Map.get("id")
      Map.get(config, "alloys", []) != [] -> config["alloys"] |> hd() |> Map.get("id")
      true -> "__targets_dispatcher__"
    end
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

  defp select_forced_model(model, targets, estimated) do
    forced = Map.get(targets, model)
    skipped = targets |> Map.delete(model) |> Map.values() |> Enum.map(&policy_skip/1)

    {selected, skipped, reason} =
      cond do
        forced == nil ->
          {nil, skipped, "policy forced model was not in the allowed route set"}

        forced["context_window"] < estimated ->
          {nil, [context_skip(forced, estimated) | skipped],
           "policy forced model was too small for estimated prompt"}

        true ->
          {forced, skipped, "policy forced selected model"}
      end

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

  defp normalize_alloy_strategy(strategy)
       when strategy in ["deterministic_all", "weighted", "round_robin"],
       do: strategy

  defp normalize_alloy_strategy("all"), do: "deterministic_all"
  defp normalize_alloy_strategy(_), do: "weighted"

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

    attrs
    |> Map.put(:selected_model, selected_model)
    |> Map.put(:selected_provider, selected_model |> String.split("/", parts: 2) |> List.first())
    |> Map.put_new(:fallback_used, false)
    |> Map.put(:route_blocked, selected == nil)
  end

  defp dispatcher_reason([], _selected), do: "estimated prompt fits selected context window"

  defp dispatcher_reason(_skipped, _selected),
    do: "estimated prompt exceeded smaller configured context windows"

  defp cascade_reason([], _selected), do: "selected first configured cascade target"

  defp cascade_reason(_skipped, _selected),
    do: "cascade skipped targets whose context windows were too small"

  defp alloy_reason(true, [], _selected_models),
    do: "partial alloy selected all constituents whose context windows fit"

  defp alloy_reason(true, _skipped, _selected_models),
    do: "partial alloy dropped smaller constituents whose context windows were too small"

  defp alloy_reason(false, [], _selected_models),
    do: "alloy constituents share a compatible context window for this prompt"

  defp alloy_reason(false, _skipped, _selected_models),
    do: "alloy prompt exceeded the compatible minimum context window"

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
      "forced_model" => Map.get(attrs, "forced_model")
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
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

      normalize_alloy_strategy(Map.get(selector, "strategy", "weighted")) !=
        Map.get(selector, "strategy", "weighted") and
          Map.get(selector, "strategy", "weighted") != "all" ->
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
end
