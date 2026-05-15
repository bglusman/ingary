defmodule Wardwright do
  @moduledoc """
  Minimal Wardwright synthetic-model mock.

  The prototype is intentionally small: one public synthetic model, mock route
  selection by estimated prompt length, and in-memory receipts.
  """

  @synthetic_model "coding-balanced"
  @synthetic_version "2026-05-13.mock"
  @local_model "local/qwen-coder"
  @managed_model "managed/kimi-k2.6"
  @local_context_window 32_768
  @managed_context_window 262_144

  def synthetic_model, do: @synthetic_model
  def synthetic_version, do: @synthetic_version
  def local_model, do: @local_model
  def managed_model, do: @managed_model
  def local_context_window, do: @local_context_window
  def managed_context_window, do: @managed_context_window

  def default_config do
    %{
      "synthetic_model" => @synthetic_model,
      "version" => @synthetic_version,
      "targets" => [
        %{"model" => @local_model, "context_window" => @local_context_window},
        %{"model" => @managed_model, "context_window" => @managed_context_window}
      ],
      "route_root" => "dispatcher.prompt_length",
      "dispatchers" => [
        %{
          "id" => "dispatcher.prompt_length",
          "name" => "Use local until prompt length requires managed context",
          "models" => [@local_model, @managed_model]
        }
      ],
      "cascades" => [],
      "alloys" => [],
      "stream_rules" => [%{"id" => "mock_noop", "pattern" => "", "action" => "pass"}],
      "prompt_transforms" => %{},
      "structured_output" => nil,
      "alert_delivery" => %{"capacity" => 16, "on_full" => "dead_letter"},
      "policy_cache" => %{"max_entries" => 64, "recent_limit" => 20},
      "governance" => [
        %{"id" => "prompt_transforms", "kind" => "request_transform", "action" => "transform"}
      ]
    }
  end

  def current_config do
    :persistent_term.get({__MODULE__, :config}, default_config())
  end

  def reset_config do
    :persistent_term.put({__MODULE__, :config}, default_config())
    Wardwright.PolicyCache.configure(default_config()["policy_cache"])
    Wardwright.Policy.AlertDelivery.configure(default_config()["alert_delivery"])
  end

  def put_config(config) when is_map(config) do
    config = normalize_config(config)

    with :ok <- validate_config(config) do
      :persistent_term.put({__MODULE__, :config}, config)
      Wardwright.PolicyCache.configure(config["policy_cache"])
      Wardwright.Policy.AlertDelivery.configure(config["alert_delivery"])
      {:ok, config}
    end
  end

  def put_config(_), do: {:error, "request body must be a JSON object"}

  def normalize_model(model) when is_binary(model) do
    model = String.trim(model)
    synthetic_model = current_config()["synthetic_model"]

    case model do
      ^synthetic_model -> {:ok, synthetic_model}
      "wardwright/" <> ^synthetic_model -> {:ok, synthetic_model}
      "" -> {:error, "model is required"}
      other -> {:error, "unknown synthetic model #{inspect(other)}"}
    end
  end

  def normalize_model(_), do: {:error, "model is required"}

  def select_route(estimated_prompt_tokens) do
    Wardwright.RoutePlanner.select(current_config(), estimated_prompt_tokens)
  end

  def select_route(estimated_prompt_tokens, attrs) when is_map(attrs) do
    Wardwright.RoutePlanner.select(current_config(), estimated_prompt_tokens, attrs)
  end

  def estimate_prompt_tokens(messages) when is_list(messages) do
    chars =
      Enum.reduce(messages, 0, fn message, acc ->
        role = message |> Map.get("role", "") |> to_string()
        acc + String.length(role) + content_length(Map.get(message, "content"))
      end)

    max(1, div(chars + 3, 4))
  end

  def estimate_prompt_tokens(_), do: 1

  defp content_length(nil), do: 0
  defp content_length(value) when is_binary(value), do: String.length(value)

  defp content_length(value) when is_list(value) do
    Enum.reduce(value, 0, fn
      %{"text" => text}, acc when is_binary(text) -> acc + String.length(text)
      %{"content" => text}, acc when is_binary(text) -> acc + String.length(text)
      part, acc -> acc + byte_size(Jason.encode!(part))
    end)
  end

  defp content_length(value), do: byte_size(Jason.encode!(value))

  def synthetic_model_record do
    config = current_config()

    targets =
      config
      |> Map.get("targets", [])
      |> Enum.sort_by(fn target -> {target["context_window"], target["model"]} end)

    target_ids = Enum.map(targets, &node_id(&1["model"]))

    nodes =
      selector_nodes(config, target_ids) ++
        Enum.map(targets, fn target ->
          %{
            "id" => node_id(target["model"]),
            "type" => "concrete_model",
            "provider_id" => target["model"] |> String.split("/", parts: 2) |> List.first(),
            "upstream_model_id" => target["model"],
            "context_window" => target["context_window"]
          }
        end)

    %{
      "id" => config["synthetic_model"],
      "public_model_id" => config["synthetic_model"],
      "active_version" => config["version"],
      "description" => "Mock coding assistant synthetic model with composable route selectors.",
      "public_namespace" => "flat",
      "route_type" => root_route_type(config),
      "status" => "active",
      "traffic_24h" => 0,
      "fallback_rate" => 0.0,
      "stream_trigger_count_24h" => 0,
      "route_graph" => %{
        "root" => Map.get(config, "route_root", "dispatcher.prompt_length"),
        "nodes" => nodes
      },
      "stream_policy" => %{
        "mode" => "buffered_horizon",
        "buffer_tokens" => 256,
        "rules" => Map.get(config, "stream_rules", [])
      },
      "prompt_transforms" => Map.get(config, "prompt_transforms", %{}),
      "structured_output" => Map.get(config, "structured_output"),
      "governance" => Map.get(config, "governance", [])
    }
  end

  def synthetic_model_summary do
    config = current_config()

    %{
      "id" => config["synthetic_model"],
      "public_model_id" => config["synthetic_model"],
      "active_version" => config["version"],
      "description" => "Mock coding assistant synthetic model with composable route selectors.",
      "public_namespace" => "flat",
      "route_type" => root_route_type(config),
      "status" => "active"
    }
  end

  defp selector_nodes(config, default_target_ids) do
    dispatchers =
      config
      |> Map.get("dispatchers", [])
      |> case do
        [] -> [%{"id" => "dispatcher.prompt_length", "models" => default_target_ids}]
        configured -> configured
      end
      |> Enum.map(fn dispatcher ->
        %{
          "id" => dispatcher["id"],
          "type" => "dispatcher",
          "targets" => selector_target_ids(dispatcher, "models"),
          "strategy" => "smallest_context_window"
        }
      end)

    cascades =
      config
      |> Map.get("cascades", [])
      |> Enum.map(fn cascade ->
        %{
          "id" => cascade["id"],
          "type" => "cascade",
          "targets" => selector_target_ids(cascade, "models"),
          "strategy" => "ordered_fallback"
        }
      end)

    alloys =
      config
      |> Map.get("alloys", [])
      |> Enum.map(fn alloy ->
        %{
          "id" => alloy["id"],
          "type" => "alloy",
          "targets" => selector_target_ids(alloy, "constituents"),
          "strategy" => Map.get(alloy, "strategy", "weighted"),
          "partial_context" => Map.get(alloy, "partial_context", false)
        }
      end)

    dispatchers ++ cascades ++ alloys
  end

  defp selector_target_ids(selector, key) do
    selector
    |> Map.get(key, Map.get(selector, "targets", []))
    |> Enum.map(fn
      model when is_binary(model) -> node_id(model)
      %{"model" => model} -> node_id(model)
      other -> node_id(to_string(other))
    end)
  end

  defp root_route_type(config) do
    root = Map.get(config, "route_root", "dispatcher.prompt_length")

    cond do
      Enum.any?(Map.get(config, "alloys", []), &(&1["id"] == root)) -> "alloy"
      Enum.any?(Map.get(config, "cascades", []), &(&1["id"] == root)) -> "cascade"
      true -> "dispatcher"
    end
  end

  def providers do
    current_config()
    |> Map.get("targets", [])
    |> Enum.reduce(%{}, fn target, acc ->
      provider = target["model"] |> String.split("/", parts: 2) |> List.first()
      Map.put_new(acc, provider, target)
    end)
    |> Enum.map(fn {provider, target} ->
      {kind, base_url} = provider_kind_and_base_url(provider, target)

      %{
        "id" => provider,
        "kind" => kind,
        "base_url" => base_url,
        "credential_owner" => "wardwright",
        "credential_source" => credential_source(target),
        "health" => "healthy"
      }
    end)
  end

  def complete_selected_model(selected_model, request) do
    started = System.monotonic_time(:millisecond)

    target =
      current_config()
      |> Map.get("targets", [])
      |> Enum.find(fn target -> target["model"] == selected_model end)

    case target do
      nil ->
        provider_outcome(nil, "completed", started, nil, false, true)

      target ->
        Wardwright.ProviderRuntime.complete(target, request, fn ->
          complete_target(target, request)
        end)
        |> provider_outcome_from_result(started)
    end
  end

  def stream_selected_model(selected_model, request) do
    started = System.monotonic_time(:millisecond)

    target =
      current_config()
      |> Map.get("targets", [])
      |> Enum.find(fn target -> target["model"] == selected_model end)

    case target do
      nil ->
        provider_outcome([], "completed", started, nil, false, true)

      target ->
        Wardwright.ProviderRuntime.stream(target, request, fn ->
          stream_target(target, request)
        end)
        |> provider_outcome_from_result(started)
        |> normalize_stream_outcome()
    end
  end

  def stream_selected_model_each(selected_model, request, acc, chunk_fun)
      when is_function(chunk_fun, 2) do
    started = System.monotonic_time(:millisecond)

    target =
      current_config()
      |> Map.get("targets", [])
      |> Enum.find(fn target -> target["model"] == selected_model end)

    case target do
      nil ->
        {result, acc} =
          stream_mock_chunks(
            [
              "Mock Wardwright stream ",
              "routed to #{selected_model} ",
              "for #{Map.get(request, "model")}."
            ],
            acc,
            chunk_fun
          )

        stream_each_outcome(acc, result, started)

      target ->
        {result, acc} =
          Wardwright.ProviderRuntime.stream_each(
            target,
            request,
            fn emit -> stream_target_each(target, request, emit) end,
            acc,
            chunk_fun
          )

        stream_each_outcome(acc, result, started)
    end
  end

  defp complete_target(target, request) do
    case provider_kind(target) do
      "mock" ->
        {:mock, nil}

      "ollama" ->
        complete_with_ollama(target, request)

      "openai-compatible" ->
        complete_with_openai_compatible(target, request)

      "canned_sequence" ->
        complete_with_canned_sequence(target, request)

      kind ->
        {:error, "unsupported provider kind #{inspect(kind)}"}
    end
  end

  defp stream_target(target, request) do
    case provider_kind(target) do
      "mock" ->
        {:mock,
         [
           "Mock Wardwright stream ",
           "routed to #{target["model"]} ",
           "for #{Map.get(request, "model")}."
         ]}

      "canned_sequence" ->
        stream_with_canned_sequence(target, request)

      "ollama" ->
        stream_with_ollama(target, request)

      "openai-compatible" ->
        stream_with_openai_compatible(target, request)

      kind ->
        {:error, "unsupported provider kind #{inspect(kind)}"}
    end
  end

  defp stream_target_each(target, request, emit) do
    case provider_kind(target) do
      "mock" ->
        [
          "Mock Wardwright stream ",
          "routed to #{target["model"]} ",
          "for #{Map.get(request, "model")}."
        ]
        |> Enum.each(emit)

        {:mock, :done}

      "canned_sequence" ->
        stream_canned_sequence_each(target, request, emit)

      "ollama" ->
        stream_ollama_each(target, request, emit)

      "openai-compatible" ->
        stream_openai_compatible_each(target, request, emit)

      kind ->
        {:error, "unsupported provider kind #{inspect(kind)}"}
    end
  end

  defp complete_with_canned_sequence(target, request) do
    delay_ms = non_negative_integer(Map.get(target, "canned_delay_ms"), 0)
    if delay_ms > 0, do: Process.sleep(delay_ms)

    outputs = Map.get(target, "canned_outputs", [])
    attempt_index = request |> Map.get("wardwright_attempt_index", 0) |> integer_value() || 0

    case Enum.at(outputs, attempt_index) || List.last(outputs) do
      output when is_binary(output) -> {:ok, output}
      _ -> {:error, "canned_sequence target has no outputs"}
    end
  end

  defp stream_with_canned_sequence(target, request) do
    delay_ms = non_negative_integer(Map.get(target, "canned_delay_ms"), 0)
    if delay_ms > 0, do: Process.sleep(delay_ms)

    attempt_index = request |> Map.get("wardwright_attempt_index", 0) |> integer_value() || 0

    chunks =
      target
      |> Map.get("canned_stream_attempt_chunks", [])
      |> attempt_stream_chunks(attempt_index)
      |> case do
        [] -> Map.get(target, "canned_stream_chunks", [])
        chunks -> chunks
      end
      |> case do
        [] ->
          target
          |> Map.get("canned_outputs", [])
          |> Enum.at(attempt_index)
          |> case do
            output when is_binary(output) -> chunk_text(output)
            _ -> []
          end

        chunks ->
          chunks
      end

    case chunks do
      chunks when is_list(chunks) and chunks != [] -> {:ok, Enum.map(chunks, &to_string/1)}
      _ -> {:error, "canned_sequence target has no stream chunks"}
    end
  end

  defp stream_canned_sequence_each(target, request, emit) do
    delay_ms = non_negative_integer(Map.get(target, "canned_delay_ms"), 0)
    stream_error = blank_to_nil(to_string(Map.get(target, "canned_stream_error", "")))

    target
    |> canned_stream_chunks(request)
    |> case do
      chunks when is_list(chunks) and chunks != [] ->
        Enum.each(chunks, fn chunk ->
          if delay_ms > 0, do: Process.sleep(delay_ms)
          emit.(to_string(chunk))
        end)

        case stream_error do
          nil -> {:ok, :done}
          reason -> {:error, reason}
        end

      _ ->
        {:error, "canned_sequence target has no stream chunks"}
    end
  end

  defp canned_stream_chunks(target, request) do
    attempt_index = request |> Map.get("wardwright_attempt_index", 0) |> integer_value() || 0

    target
    |> Map.get("canned_stream_attempt_chunks", [])
    |> attempt_stream_chunks(attempt_index)
    |> case do
      [] -> Map.get(target, "canned_stream_chunks", [])
      chunks -> chunks
    end
    |> case do
      [] ->
        target
        |> Map.get("canned_outputs", [])
        |> Enum.at(attempt_index)
        |> case do
          output when is_binary(output) -> chunk_text(output)
          _ -> []
        end

      chunks ->
        chunks
    end
  end

  defp attempt_stream_chunks(attempt_chunks, attempt_index)
       when is_list(attempt_chunks) and is_integer(attempt_index) do
    case Enum.at(attempt_chunks, attempt_index) do
      chunks when is_list(chunks) -> chunks
      _ -> []
    end
  end

  defp attempt_stream_chunks(_attempt_chunks, _attempt_index), do: []

  defp chunk_text(text) when is_binary(text) do
    [text]
  end

  defp normalize_config(config) do
    %{
      "synthetic_model" =>
        config |> Map.get("synthetic_model", "") |> to_string() |> String.trim(),
      "version" =>
        config
        |> Map.get("version", @synthetic_version)
        |> to_string()
        |> String.trim()
        |> then(fn
          "" -> @synthetic_version
          version -> version
        end),
      "targets" =>
        config
        |> Map.get("targets", [])
        |> Enum.map(fn target ->
          %{
            "model" => target |> Map.get("model", "") |> to_string() |> String.trim(),
            "context_window" => integer_value(Map.get(target, "context_window")),
            "provider_kind" =>
              target |> Map.get("provider_kind", "") |> to_string() |> String.trim(),
            "provider_base_url" =>
              target |> Map.get("provider_base_url", "") |> to_string() |> String.trim(),
            "provider_headers" => normalize_headers(Map.get(target, "provider_headers", %{})),
            "credential_env" =>
              target |> Map.get("credential_env", "") |> to_string() |> String.trim(),
            "credential_fnox_key" =>
              target |> Map.get("credential_fnox_key", "") |> to_string() |> String.trim(),
            "canned_outputs" => normalize_canned_outputs(Map.get(target, "canned_outputs", [])),
            "canned_stream_chunks" =>
              normalize_canned_outputs(Map.get(target, "canned_stream_chunks", [])),
            "canned_stream_attempt_chunks" =>
              normalize_canned_stream_attempt_chunks(
                Map.get(target, "canned_stream_attempt_chunks", [])
              ),
            "canned_stream_error" =>
              target |> Map.get("canned_stream_error", "") |> to_string() |> String.trim(),
            "canned_delay_ms" => non_negative_integer(Map.get(target, "canned_delay_ms"), 0),
            "provider_timeout_ms" =>
              positive_integer(Map.get(target, "provider_timeout_ms"), 180_000)
          }
          |> Enum.reject(fn {_key, value} -> value == "" or value == [] end)
          |> Map.new()
        end),
      "route_root" =>
        config
        |> Map.get("route_root", "dispatcher.prompt_length")
        |> to_string()
        |> String.trim()
        |> then(fn
          "" -> "dispatcher.prompt_length"
          route_root -> route_root
        end),
      "dispatchers" => normalize_selectors(Map.get(config, "dispatchers", []), "models"),
      "cascades" => normalize_selectors(Map.get(config, "cascades", []), "models"),
      "alloys" => normalize_selectors(Map.get(config, "alloys", []), "constituents"),
      "stream_rules" => Map.get(config, "stream_rules", []),
      "prompt_transforms" => Map.get(config, "prompt_transforms", %{}),
      "structured_output" => Map.get(config, "structured_output"),
      "alert_delivery" => normalize_alert_delivery(Map.get(config, "alert_delivery", %{})),
      "policy_cache" => normalize_policy_cache(Map.get(config, "policy_cache", %{})),
      "governance" => Map.get(config, "governance", [])
    }
  end

  defp normalize_canned_outputs(outputs) when is_list(outputs),
    do: Enum.map(outputs, &to_string/1)

  defp normalize_canned_outputs(_), do: []

  defp normalize_canned_stream_attempt_chunks(attempts) when is_list(attempts) do
    Enum.map(attempts, &normalize_canned_outputs/1)
  end

  defp normalize_canned_stream_attempt_chunks(_), do: []

  defp normalize_selectors(selectors, model_key) when is_list(selectors) do
    Enum.map(selectors, fn selector ->
      %{
        "id" => selector |> Map.get("id", "") |> to_string() |> String.trim(),
        "name" => selector |> Map.get("name", "") |> to_string() |> String.trim(),
        "strategy" => selector |> Map.get("strategy", "") |> to_string() |> String.trim(),
        "partial_context" => Map.get(selector, "partial_context", false) == true,
        "min_context_window" => integer_value(Map.get(selector, "min_context_window")),
        "fallback_model" =>
          selector |> Map.get("fallback_model", "") |> to_string() |> String.trim(),
        model_key =>
          normalize_selector_models(
            Map.get(selector, model_key, Map.get(selector, "targets", []))
          )
      }
      |> Enum.reject(fn {_key, value} -> value in ["", nil, []] end)
      |> Map.new()
    end)
  end

  defp normalize_selectors(_selectors, _model_key), do: []

  defp normalize_selector_models(models) when is_list(models) do
    Enum.map(models, fn
      model when is_binary(model) ->
        String.trim(model)

      model when is_map(model) ->
        %{
          "model" => model |> Map.get("model", "") |> to_string() |> String.trim(),
          "context_window" => integer_value(Map.get(model, "context_window")),
          "weight" => integer_value(Map.get(model, "weight"))
        }
        |> Enum.reject(fn {_key, value} -> value in ["", nil] end)
        |> Map.new()

      model ->
        to_string(model)
    end)
  end

  defp normalize_selector_models(_models), do: []

  defp normalize_alert_delivery(config) when is_map(config) do
    %{
      "capacity" => non_negative_integer(Map.get(config, "capacity"), 16),
      "on_full" =>
        case Map.get(config, "on_full") do
          value when value in ["drop", "dead_letter", "fail_closed"] -> value
          _ -> "dead_letter"
        end
    }
  end

  defp normalize_alert_delivery(_), do: %{"capacity" => 16, "on_full" => "dead_letter"}

  defp normalize_policy_cache(config) when is_map(config) do
    %{
      "max_entries" => positive_integer(Map.get(config, "max_entries"), 64),
      "recent_limit" => positive_integer(Map.get(config, "recent_limit"), 20)
    }
  end

  defp normalize_policy_cache(_), do: %{"max_entries" => 64, "recent_limit" => 20}

  defp validate_config(config = %{"synthetic_model" => synthetic_model, "targets" => targets}) do
    cond do
      synthetic_model == "" ->
        {:error, "synthetic_model must not be empty"}

      String.contains?(synthetic_model, "/") ->
        {:error, "synthetic_model must be unprefixed"}

      targets == [] ->
        {:error, "targets must not be empty"}

      true ->
        with :ok <- validate_targets(targets) do
          Wardwright.RoutePlanner.validate(config)
        end
    end
  end

  defp validate_targets(targets) do
    Enum.reduce_while(targets, MapSet.new(), fn target, seen ->
      cond do
        target["model"] == "" ->
          {:halt, {:error, "target model must not be empty"}}

        not is_integer(target["context_window"]) or target["context_window"] <= 0 ->
          {:halt, {:error, "target #{target["model"]} context_window must be positive"}}

        MapSet.member?(seen, target["model"]) ->
          {:halt, {:error, "duplicate target #{target["model"]}"}}

        credential_reference?(target) and
            System.get_env("WARDWRIGHT_ALLOW_TEST_CREDENTIALS") != "1" ->
          {:halt,
           {:error,
            "credential references in __test/config require WARDWRIGHT_ALLOW_TEST_CREDENTIALS=1"}}

        true ->
          {:cont, MapSet.put(seen, target["model"])}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      other -> other
    end
  end

  defp node_id(model), do: String.replace(model, "/", ".")

  defp credential_reference?(target) do
    Map.get(target, "credential_env", "") != "" or
      Map.get(target, "credential_fnox_key", "") != ""
  end

  defp provider_kind_and_base_url(provider, target) do
    kind = provider_kind(target)
    base_url = Map.get(target, "provider_base_url", "")

    cond do
      base_url != "" ->
        {kind, base_url}

      provider == "ollama" ->
        {"ollama", System.get_env("OLLAMA_BASE_URL", "http://127.0.0.1:11434")}

      true ->
        {kind, "mock://#{provider}"}
    end
  end

  defp provider_kind(target) do
    cond do
      Map.get(target, "provider_kind", "") != "" -> target["provider_kind"]
      String.starts_with?(target["model"], "ollama/") -> "ollama"
      true -> "mock"
    end
  end

  defp credential_source(target) do
    cond do
      Map.get(target, "credential_fnox_key", "") != "" -> "fnox"
      Map.get(target, "credential_env", "") != "" -> "env"
      true -> "none"
    end
  end

  defp complete_with_ollama(target, request) do
    model = provider_model(target)

    base_url =
      Map.get(target, "provider_base_url") ||
        System.get_env("OLLAMA_BASE_URL", "http://127.0.0.1:11434")

    body =
      Jason.encode!(%{
        model: model,
        messages: request_messages(request),
        stream: false
      })

    http_post("#{String.trim_trailing(base_url, "/")}/api/chat", body, [])
    |> case do
      {:ok, response} -> {:ok, get_in(response, ["message", "content"]) || ""}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream_with_ollama(target, request) do
    model = provider_model(target)

    base_url =
      Map.get(target, "provider_base_url") ||
        System.get_env("OLLAMA_BASE_URL", "http://127.0.0.1:11434")

    body =
      Jason.encode!(%{
        model: model,
        messages: request_messages(request),
        stream: true
      })

    "#{String.trim_trailing(base_url, "/")}/api/chat"
    |> http_post_stream(body, [])
    |> case do
      {:ok, response_body} -> {:ok, parse_ollama_stream_chunks(response_body)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream_ollama_each(target, request, emit) do
    model = provider_model(target)

    base_url =
      Map.get(target, "provider_base_url") ||
        System.get_env("OLLAMA_BASE_URL", "http://127.0.0.1:11434")

    body =
      Jason.encode!(%{
        model: model,
        messages: request_messages(request),
        stream: true
      })

    "#{String.trim_trailing(base_url, "/")}/api/chat"
    |> http_post_stream_each(body, [], {:lines, ""}, &parse_ollama_stream_part/3, emit)
  end

  defp complete_with_openai_compatible(target, request) do
    with base_url when base_url != "" <- Map.get(target, "provider_base_url", ""),
         {:ok, credential} <- provider_credential(target) do
      body =
        Jason.encode!(%{
          model: provider_model(target),
          messages: request_messages(request),
          stream: false
        })

      headers = provider_headers(target) ++ [{~c"authorization", ~c"Bearer #{credential}"}]

      "#{String.trim_trailing(base_url, "/")}/chat/completions"
      |> http_post(body, headers)
      |> case do
        {:ok, response} ->
          {:ok, get_in(response, ["choices", Access.at(0), "message", "content"]) || ""}

        {:error, reason} ->
          {:error, reason}
      end
    else
      "" -> {:error, "provider_base_url is required for openai-compatible targets"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream_with_openai_compatible(target, request) do
    with base_url when base_url != "" <- Map.get(target, "provider_base_url", ""),
         {:ok, credential} <- provider_credential(target) do
      body =
        Jason.encode!(%{
          model: provider_model(target),
          messages: request_messages(request),
          stream: true
        })

      headers = provider_headers(target) ++ [{~c"authorization", ~c"Bearer #{credential}"}]

      "#{String.trim_trailing(base_url, "/")}/chat/completions"
      |> http_post_stream(body, headers)
      |> case do
        {:ok, response_body} -> {:ok, parse_openai_sse_chunks(response_body)}
        {:error, reason} -> {:error, reason}
      end
    else
      "" -> {:error, "provider_base_url is required for openai-compatible targets"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream_openai_compatible_each(target, request, emit) do
    with base_url when base_url != "" <- Map.get(target, "provider_base_url", ""),
         {:ok, credential} <- provider_credential(target) do
      body =
        Jason.encode!(%{
          model: provider_model(target),
          messages: request_messages(request),
          stream: true
        })

      headers = provider_headers(target) ++ [{~c"authorization", ~c"Bearer #{credential}"}]

      "#{String.trim_trailing(base_url, "/")}/chat/completions"
      |> http_post_stream_each(body, headers, {:sse, ""}, &parse_openai_sse_part/3, emit)
    else
      "" -> {:error, "provider_base_url is required for openai-compatible targets"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp http_post(url, body, headers) do
    request = {
      String.to_charlist(url),
      [{~c"content-type", ~c"application/json"} | headers],
      ~c"application/json",
      body
    }

    case :httpc.request(:post, request, [{:timeout, 180_000}], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, response_body}} when status in 200..299 ->
        Jason.decode(response_body)

      {:ok, {{_, status, _}, _headers, _response_body}} ->
        {:error, "provider returned #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp http_post_stream(url, body, headers) do
    request = {
      String.to_charlist(url),
      [{~c"content-type", ~c"application/json"} | headers],
      ~c"application/json",
      body
    }

    case :httpc.request(
           :post,
           request,
           [{:timeout, 180_000}],
           sync: false,
           stream: {:self, :once}
         ) do
      {:ok, request_id} ->
        collect_http_stream(request_id, [], nil)

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp http_post_stream_each(url, body, headers, parser_state, parser_fun, emit) do
    request = {
      String.to_charlist(url),
      [{~c"content-type", ~c"application/json"} | headers],
      ~c"application/json",
      body
    }

    case :httpc.request(
           :post,
           request,
           [{:timeout, 180_000}],
           sync: false,
           stream: {:self, :once}
         ) do
      {:ok, request_id} ->
        collect_http_stream_each(request_id, nil, parser_state, parser_fun, emit)

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp collect_http_stream(request_id, parts, handler_pid) do
    receive do
      {:http, {^request_id, :stream_start, _headers, pid}} ->
        :ok = :httpc.stream_next(pid)
        collect_http_stream(request_id, parts, pid)

      {:http, {^request_id, :stream_start, _headers}} ->
        collect_http_stream(request_id, parts, handler_pid)

      {:http, {^request_id, :stream, part}} ->
        if handler_pid, do: :ok = :httpc.stream_next(handler_pid)
        collect_http_stream(request_id, [part | parts], handler_pid)

      {:http, {^request_id, :stream_end, _headers}} ->
        {:ok, parts |> Enum.reverse() |> IO.iodata_to_binary()}

      {:http, {^request_id, {{_, status, _}, _headers, response_body}}}
      when status in 200..299 ->
        {:ok, response_body}

      {:http, {^request_id, {{_, status, _}, _headers, _response_body}}} ->
        {:error, "provider returned #{status}"}

      {:http, {^request_id, {:error, reason}}} ->
        {:error, inspect(reason)}
    after
      180_000 ->
        :httpc.cancel_request(request_id)
        {:error, "provider stream timed out after 180000ms"}
    end
  end

  defp collect_http_stream_each(request_id, handler_pid, parser_state, parser_fun, emit) do
    receive do
      {_stream_ref, :cancel} ->
        :httpc.cancel_request(request_id)
        {:error, "provider stream cancelled"}

      {:http, {^request_id, :stream_start, _headers, pid}} ->
        :ok = :httpc.stream_next(pid)
        collect_http_stream_each(request_id, pid, parser_state, parser_fun, emit)

      {:http, {^request_id, :stream_start, _headers}} ->
        collect_http_stream_each(request_id, handler_pid, parser_state, parser_fun, emit)

      {:http, {^request_id, :stream, part}} ->
        if handler_pid, do: :ok = :httpc.stream_next(handler_pid)
        parser_state = parser_fun.(IO.iodata_to_binary(part), parser_state, emit)
        collect_http_stream_each(request_id, handler_pid, parser_state, parser_fun, emit)

      {:http, {^request_id, :stream_end, _headers}} ->
        finalize_stream_parser(parser_state, parser_fun, emit)
        :ok

      {:http, {^request_id, {{_, status, _}, _headers, response_body}}}
      when status in 200..299 ->
        response_body
        |> IO.iodata_to_binary()
        |> parser_fun.(parser_state, emit)
        |> finalize_stream_parser(parser_fun, emit)

        :ok

      {:http, {^request_id, {{_, status, _}, _headers, _response_body}}} ->
        {:error, "provider returned #{status}"}

      {:http, {^request_id, {:error, reason}}} ->
        {:error, inspect(reason)}
    after
      180_000 ->
        :httpc.cancel_request(request_id)
        {:error, "provider stream timed out after 180000ms"}
    end
    |> case do
      :ok -> {:ok, :done}
      error -> error
    end
  end

  defp parse_ollama_stream_part(part, {:lines, pending}, emit) do
    {lines, pending} = split_stream_lines(pending <> part)

    Enum.each(lines, fn line ->
      case Jason.decode(String.trim(line)) do
        {:ok, event} ->
          content = get_in(event, ["message", "content"]) || event["response"]
          if content not in [nil, ""], do: emit.(content)

        {:error, _} ->
          :ok
      end
    end)

    {:lines, pending}
  end

  defp finalize_stream_parser({:lines, _pending} = parser_state, parser_fun, emit) do
    parser_fun.("\n", parser_state, emit)
  end

  defp finalize_stream_parser({:sse, _pending} = parser_state, parser_fun, emit) do
    parser_fun.("\n\n", parser_state, emit)
  end

  defp parse_openai_sse_part(part, {:sse, pending}, emit) do
    {events, pending} = split_sse_events(pending <> part)

    Enum.each(events, fn event ->
      event
      |> String.split(["\r\n", "\n"], trim: true)
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(fn "data: " <> data -> String.trim(data) end)
      |> Enum.each(fn
        "[DONE]" ->
          :ok

        data ->
          case Jason.decode(data) do
            {:ok, event} ->
              content =
                get_in(event, ["choices", Access.at(0), "delta", "content"]) ||
                  get_in(event, ["choices", Access.at(0), "message", "content"])

              if content not in [nil, ""], do: emit.(content)

            {:error, _} ->
              :ok
          end
      end)
    end)

    {:sse, pending}
  end

  defp split_stream_lines(buffer) do
    parts = String.split(buffer, ["\r\n", "\n"])

    case parts do
      [] -> {[], ""}
      parts -> {Enum.slice(parts, 0, max(length(parts) - 1, 0)), List.last(parts) || ""}
    end
  end

  defp split_sse_events(buffer) do
    cond do
      String.contains?(buffer, "\n\n") ->
        parts = String.split(buffer, "\n\n")
        {Enum.slice(parts, 0, max(length(parts) - 1, 0)), List.last(parts) || ""}

      String.contains?(buffer, "\r\n\r\n") ->
        parts = String.split(buffer, "\r\n\r\n")
        {Enum.slice(parts, 0, max(length(parts) - 1, 0)), List.last(parts) || ""}

      true ->
        {[], buffer}
    end
  end

  defp parse_ollama_stream_chunks(response_body) do
    response_body
    |> stream_lines()
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, event} -> [get_in(event, ["message", "content"]) || event["response"]]
        {:error, _} -> []
      end
    end)
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp parse_openai_sse_chunks(response_body) do
    response_body
    |> stream_lines()
    |> Enum.flat_map(fn
      "data: [DONE]" ->
        []

      "data: " <> data ->
        case Jason.decode(data) do
          {:ok, event} ->
            [
              get_in(event, ["choices", Access.at(0), "delta", "content"]) ||
                get_in(event, ["choices", Access.at(0), "message", "content"])
            ]

          {:error, _} ->
            []
        end

      _line ->
        []
    end)
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp stream_lines(response_body) when is_binary(response_body) do
    response_body
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp provider_credential(target) do
    cond do
      Map.get(target, "credential_env", "") != "" ->
        key = target["credential_env"]

        case System.get_env(key) |> blank_to_nil() do
          nil -> {:error, "credential env var #{key} is not set"}
          value -> {:ok, value}
        end

      Map.get(target, "credential_fnox_key", "") != "" ->
        key = target["credential_fnox_key"]

        case System.cmd("fnox", ["get", key], stderr_to_stdout: false) do
          {value, 0} ->
            case blank_to_nil(value) do
              nil -> {:error, "fnox credential #{key} is empty"}
              value -> {:ok, value}
            end

          {_output, _status} ->
            {:error, "fnox credential #{key} is unavailable"}
        end

      true ->
        {:error, "credential_env or credential_fnox_key is required"}
    end
  end

  defp provider_model(target) do
    target["model"]
    |> String.split("/", parts: 2)
    |> case do
      [_provider, model] -> model
      [model] -> model
    end
  end

  defp normalize_headers(headers) when is_map(headers) do
    headers
    |> Enum.map(fn {key, value} ->
      {key |> to_string() |> String.trim(), value |> to_string() |> String.trim()}
    end)
    |> Enum.reject(fn {key, value} ->
      key == "" or value == "" or String.downcase(key) == "authorization"
    end)
    |> Map.new()
  end

  defp normalize_headers(_), do: %{}

  defp provider_headers(target) do
    target
    |> Map.get("provider_headers", %{})
    |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  defp request_messages(request) do
    request
    |> Map.get("messages", [])
    |> Enum.map(fn message ->
      %{
        role: Map.get(message, "role", ""),
        content: content_string(Map.get(message, "content"))
      }
    end)
  end

  defp content_string(value) when is_binary(value), do: value
  defp content_string(nil), do: ""
  defp content_string(value), do: Jason.encode!(value)

  defp provider_outcome_from_result({:ok, content}, started) do
    provider_outcome(content, "completed", started, nil, true, false)
  end

  defp provider_outcome_from_result({:mock, content}, started) do
    provider_outcome(content, "completed", started, nil, false, true)
  end

  defp provider_outcome_from_result({:error, reason}, started) do
    provider_outcome(nil, "provider_error", started, reason, true, false)
  end

  defp provider_outcome(content, status, started, error, called_provider, mock) do
    %{
      content: content,
      status: status,
      latency_ms: max(0, System.monotonic_time(:millisecond) - started),
      error: error,
      called_provider: called_provider,
      mock: mock
    }
  end

  defp normalize_stream_outcome(%{content: chunks} = outcome) when is_list(chunks) do
    outcome
    |> Map.put(:content, Enum.join(chunks, ""))
    |> Map.put(:stream_chunks, chunks)
  end

  defp normalize_stream_outcome(outcome), do: outcome

  defp stream_mock_chunks(chunks, acc, chunk_fun) do
    Enum.reduce_while(chunks, {{:mock, :done}, acc}, fn chunk, {_result, acc} ->
      case chunk_fun.(chunk, acc) do
        {:cont, acc} -> {:cont, {{:mock, :done}, acc}}
        {:halt, acc} -> {:halt, {{:halted, :cancelled}, acc}}
      end
    end)
  end

  defp stream_each_outcome(acc, result, started) do
    provider =
      case result do
        {:ok, _} -> provider_outcome(nil, "completed", started, nil, true, false)
        {:mock, _} -> provider_outcome(nil, "completed", started, nil, false, true)
        {:halted, _} -> provider_outcome(nil, "cancelled", started, nil, true, false)
        {:error, reason} -> provider_outcome(nil, "provider_error", started, reason, true, false)
        _ -> provider_outcome(nil, "provider_error", started, inspect(result), true, false)
      end

    {provider, acc}
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp integer_value(_), do: nil

  defp positive_integer(value, default) do
    case integer_value(value) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp non_negative_integer(value, default) do
    case integer_value(value) do
      value when is_integer(value) and value >= 0 -> value
      _ -> default
    end
  end
end
