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
      "stream_rules" => [%{"id" => "mock_noop", "pattern" => "", "action" => "pass"}],
      "prompt_transforms" => %{},
      "structured_output" => nil,
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
  end

  def put_config(config) when is_map(config) do
    config = normalize_config(config)

    with :ok <- validate_config(config) do
      :persistent_term.put({__MODULE__, :config}, config)
      Wardwright.PolicyCache.configure(config["policy_cache"])
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
    targets =
      current_config()
      |> Map.get("targets", [])
      |> Enum.sort_by(fn target -> {target["context_window"], target["model"]} end)

    {selected, skipped} =
      Enum.reduce_while(targets, {List.last(targets), []}, fn target, {_selected, skipped} ->
        if target["context_window"] >= estimated_prompt_tokens do
          {:halt, {target, skipped}}
        else
          skipped = [
            %{
              "target" => target["model"],
              "reason" => "context_window_too_small",
              "context_window" => target["context_window"]
            }
            | skipped
          ]

          {:cont, {target, skipped}}
        end
      end)

    selected_model =
      case selected do
        %{"model" => model} -> model
        _ -> "unconfigured/no-target"
      end

    %{
      selected_model: selected_model,
      selected_provider: selected_model |> String.split("/", parts: 2) |> List.first(),
      estimated_prompt_tokens: estimated_prompt_tokens,
      skipped: Enum.reverse(skipped),
      reason:
        if skipped == [] do
          "estimated prompt fits selected context window"
        else
          "estimated prompt exceeded smaller configured context windows"
        end
    }
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
      [
        %{
          "id" => "dispatcher.prompt_length",
          "type" => "dispatcher",
          "targets" => target_ids,
          "strategy" => "estimated_prompt_length"
        }
      ] ++
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
      "description" => "Mock coding assistant synthetic model with prompt-length dispatch.",
      "public_namespace" => "flat",
      "route_type" => "dispatcher",
      "status" => "active",
      "traffic_24h" => 0,
      "fallback_rate" => 0.0,
      "stream_trigger_count_24h" => 0,
      "route_graph" => %{
        "root" => "dispatcher.prompt_length",
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
        case provider_kind(target) do
          "mock" ->
            provider_outcome(nil, "completed", started, nil, false, true)

          "ollama" ->
            target
            |> complete_with_ollama(request)
            |> provider_outcome_from_result(started)

          "openai-compatible" ->
            target
            |> complete_with_openai_compatible(request)
            |> provider_outcome_from_result(started)

          kind ->
            provider_outcome(
              nil,
              "provider_error",
              started,
              "unsupported provider kind #{inspect(kind)}",
              true,
              false
            )
        end
    end
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
              target |> Map.get("credential_fnox_key", "") |> to_string() |> String.trim()
          }
          |> Enum.reject(fn {_key, value} -> value == "" end)
          |> Map.new()
        end),
      "stream_rules" => Map.get(config, "stream_rules", []),
      "prompt_transforms" => Map.get(config, "prompt_transforms", %{}),
      "structured_output" => Map.get(config, "structured_output"),
      "policy_cache" => normalize_policy_cache(Map.get(config, "policy_cache", %{})),
      "governance" => Map.get(config, "governance", [])
    }
  end

  defp normalize_policy_cache(config) when is_map(config) do
    %{
      "max_entries" => positive_integer(Map.get(config, "max_entries"), 64),
      "recent_limit" => positive_integer(Map.get(config, "recent_limit"), 20)
    }
  end

  defp normalize_policy_cache(_), do: %{"max_entries" => 64, "recent_limit" => 20}

  defp validate_config(%{"synthetic_model" => synthetic_model, "targets" => targets}) do
    cond do
      synthetic_model == "" ->
        {:error, "synthetic_model must not be empty"}

      String.contains?(synthetic_model, "/") ->
        {:error, "synthetic_model must be unprefixed"}

      targets == [] ->
        {:error, "targets must not be empty"}

      true ->
        validate_targets(targets)
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
end
