defmodule Wardwright.LiveProviderSmokeTest do
  use Wardwright.RouterCase

  @moduletag :live_provider

  @prompt "Reply with exactly this phrase and no markdown: wardwright live smoke ok"

  test "configured live provider targets stream through Wardwright and record provider metadata" do
    targets = live_targets()

    if targets == [] do
      flunk("""
      no live provider targets configured

      Set WARDWRIGHT_LIVE_OLLAMA_MODEL for local Ollama and/or
      WARDWRIGHT_LIVE_OPENAI_MODEL, WARDWRIGHT_LIVE_OPENAI_BASE_URL, and
      WARDWRIGHT_LIVE_OPENAI_API_KEY for an OpenAI-compatible provider.
      """)
    end

    Enum.each(targets, &smoke_target!/1)
  end

  defp smoke_target!(target) do
    config =
      unit_policy_config()
      |> Map.put("synthetic_model", "live-smoke")
      |> Map.put("version", "live-provider-smoke")
      |> Map.put("targets", [target.config])
      |> Map.put("governance", [])
      |> Map.put("stream_rules", [])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/chat/completions", %{
        model: "live-smoke",
        stream: true,
        messages: [%{role: "user", content: @prompt}]
      })

    assert conn.status == 200, live_failure_message(target, conn)
    assert get_resp_header(conn, "content-type") == ["text/event-stream"]

    streamed_text = streamed_text(conn.resp_body)
    assert String.trim(streamed_text) != ""

    [receipt_id] = get_resp_header(conn, "x-wardwright-receipt-id")
    receipt = Wardwright.ReceiptStore.get(receipt_id)

    assert get_in(receipt, ["attempts", Access.at(0), "called_provider"]) == true
    assert get_in(receipt, ["attempts", Access.at(0), "mock"]) == false

    assert get_in(receipt, ["final", "provider_metadata", "stream_format"]) ==
             target.stream_format

    assert get_in(receipt, ["final", "stream_policy", "released_to_consumer"]) == true

    assert get_in(receipt, ["final", "provider_metadata", "done"]) in [true, nil]
  end

  defp live_targets do
    [ollama_target(), openai_compatible_target()]
    |> Enum.reject(&is_nil/1)
  end

  defp ollama_target do
    case env("WARDWRIGHT_LIVE_OLLAMA_MODEL") do
      nil ->
        nil

      model ->
        %{
          stream_format: "ollama_ndjson",
          config: %{
            "model" => "ollama/#{model}",
            "context_window" => positive_env("WARDWRIGHT_LIVE_OLLAMA_CONTEXT", 32_768),
            "provider_kind" => "ollama",
            "provider_base_url" =>
              env("WARDWRIGHT_LIVE_OLLAMA_BASE_URL") || "http://127.0.0.1:11434",
            "provider_timeout_ms" => positive_env("WARDWRIGHT_LIVE_PROVIDER_TIMEOUT_MS", 30_000)
          }
        }
    end
  end

  defp openai_compatible_target do
    with model when not is_nil(model) <- env("WARDWRIGHT_LIVE_OPENAI_MODEL"),
         base_url when not is_nil(base_url) <- env("WARDWRIGHT_LIVE_OPENAI_BASE_URL"),
         credential when not is_nil(credential) <- env("WARDWRIGHT_LIVE_OPENAI_API_KEY") do
      System.put_env("WARDWRIGHT_LIVE_OPENAI_API_KEY", credential)

      %{
        stream_format: "openai_sse",
        config: %{
          "model" => "openai-compatible/#{model}",
          "context_window" => positive_env("WARDWRIGHT_LIVE_OPENAI_CONTEXT", 128_000),
          "provider_kind" => "openai-compatible",
          "provider_base_url" => base_url,
          "credential_env" => "WARDWRIGHT_LIVE_OPENAI_API_KEY",
          "provider_timeout_ms" => positive_env("WARDWRIGHT_LIVE_PROVIDER_TIMEOUT_MS", 30_000)
        }
      }
    else
      _ -> nil
    end
  end

  defp streamed_text(resp_body) do
    resp_body
    |> String.split("\n\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.map(&(&1 |> String.replace_prefix("data:", "") |> String.trim()))
    |> Enum.reject(&(&1 == "[DONE]"))
    |> Enum.map(&Jason.decode!/1)
    |> Enum.map(&(get_in(&1, ["choices", Access.at(0), "delta", "content"]) || ""))
    |> Enum.join()
  end

  defp live_failure_message(target, conn) do
    """
    expected live provider #{target.config["model"]} to stream successfully,
    got status #{conn.status} with body:
    #{conn.resp_body}
    """
  end

  defp env(name) do
    case System.get_env(name) do
      nil -> nil
      value -> if String.trim(value) == "", do: nil, else: String.trim(value)
    end
  end

  defp positive_env(name, default) do
    case env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  rescue
    ArgumentError -> default
  end
end
