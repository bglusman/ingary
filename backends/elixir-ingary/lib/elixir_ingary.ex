defmodule ElixirIngary do
  @moduledoc """
  Minimal Ingary synthetic-model mock.

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
  end

  def put_config(config) when is_map(config) do
    config = normalize_config(config)

    with :ok <- validate_config(config) do
      :persistent_term.put({__MODULE__, :config}, config)
      {:ok, config}
    end
  end

  def put_config(_), do: {:error, "request body must be a JSON object"}

  def normalize_model(model) when is_binary(model) do
    model = String.trim(model)
    synthetic_model = current_config()["synthetic_model"]

    case model do
      ^synthetic_model -> {:ok, synthetic_model}
      "ingary/" <> ^synthetic_model -> {:ok, synthetic_model}
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
    |> Enum.map(fn target -> target["model"] |> String.split("/", parts: 2) |> List.first() end)
    |> Enum.uniq()
    |> Enum.map(fn provider ->
      %{
        "id" => provider,
        "kind" => "mock",
        "base_url" => "mock://#{provider}",
        "credential_owner" => "ingary",
        "health" => "healthy"
      }
    end)
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
            "context_window" => integer_value(Map.get(target, "context_window"))
          }
        end),
      "stream_rules" => Map.get(config, "stream_rules", []),
      "prompt_transforms" => Map.get(config, "prompt_transforms", %{}),
      "structured_output" => Map.get(config, "structured_output"),
      "governance" => Map.get(config, "governance", [])
    }
  end

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

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp integer_value(_), do: nil
end
