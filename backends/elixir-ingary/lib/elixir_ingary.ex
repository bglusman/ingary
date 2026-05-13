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

  def normalize_model(model) when is_binary(model) do
    model = String.trim(model)

    case model do
      @synthetic_model -> {:ok, @synthetic_model}
      "ingary/" <> @synthetic_model -> {:ok, @synthetic_model}
      "" -> {:error, "model is required"}
      other -> {:error, "unknown synthetic model #{inspect(other)}"}
    end
  end

  def normalize_model(_), do: {:error, "model is required"}

  def select_provider_model(estimated_prompt_tokens)
      when estimated_prompt_tokens <= @local_context_window,
      do: @local_model

  def select_provider_model(_estimated_prompt_tokens), do: @managed_model

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
    %{
      "id" => @synthetic_model,
      "public_model_id" => @synthetic_model,
      "active_version" => @synthetic_version,
      "description" => "Mock coding assistant synthetic model with prompt-length dispatch.",
      "public_namespace" => "prefixed",
      "route_type" => "dispatcher",
      "status" => "active",
      "traffic_24h" => 0,
      "fallback_rate" => 0.0,
      "stream_trigger_count_24h" => 0,
      "route_graph" => %{
        "root" => "prompt-length-dispatcher",
        "nodes" => [
          %{
            "id" => "prompt-length-dispatcher",
            "type" => "dispatcher",
            "targets" => [@local_model, @managed_model],
            "strategy" => "estimated_prompt_length"
          },
          %{
            "id" => @local_model,
            "type" => "concrete_model",
            "provider_id" => "local",
            "upstream_model_id" => "qwen-coder",
            "context_window" => @local_context_window
          },
          %{
            "id" => @managed_model,
            "type" => "concrete_model",
            "provider_id" => "managed",
            "upstream_model_id" => "kimi-k2.6",
            "context_window" => @managed_context_window
          }
        ]
      },
      "stream_policy" => %{
        "mode" => "pass_through",
        "buffer_tokens" => 0,
        "rules" => []
      }
    }
  end

  def providers do
    [
      %{
        "id" => "local",
        "kind" => "mock",
        "base_url" => "mock://local",
        "credential_owner" => "ingary",
        "health" => "healthy"
      },
      %{
        "id" => "managed",
        "kind" => "mock",
        "base_url" => "mock://managed",
        "credential_owner" => "ingary",
        "health" => "healthy"
      }
    ]
  end
end
