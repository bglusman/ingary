defmodule Wardwright.StreamProviderTransportTest do
  use Wardwright.RouterCase

  test "ollama stream targets use provider HTTP chunks for stream policy decisions" do
    base_url = streaming_provider_base_url("/ollama")

    config =
      unit_policy_config()
      |> Map.put("targets", [
        %{
          "model" => "ollama/live-test",
          "context_window" => 256,
          "provider_base_url" => base_url
        }
      ])
      |> Map.put("governance", [])
      |> Map.put("stream_rules", [
        %{
          "id" => "ollama-stream-split-retry",
          "contains" => "OldClient(",
          "action" => "retry_with_reminder",
          "reminder" => "Use NewClient instead.",
          "max_retries" => 0
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/chat/completions", %{
        model: "unit-model",
        stream: true,
        messages: [%{role: "user", content: "stream code"}]
      })

    assert conn.status == 409

    body = Jason.decode!(conn.resp_body)
    stream_policy = get_in(body, ["wardwright", "stream_policy"])

    assert get_in(body, ["wardwright", "status"]) == "stream_policy_retry_required"
    assert stream_policy["released_to_consumer"] == false
    assert stream_policy["released_bytes"] == 0

    assert [
             %{
               "status" => "stream_policy_retry_required",
               "called_provider" => true,
               "mock" => false,
               "provider_status" => "cancelled"
             }
           ] = stream_policy["attempts"]

    assert [
             %{
               "rule_id" => "ollama-stream-split-retry",
               "match_scope" => "stream_window"
             }
           ] = stream_policy["events"]
  end

  test "ollama stream retry_with_reminder injects the reminder into the next provider request" do
    base_url = streaming_provider_base_url("/ollama")

    config =
      unit_policy_config()
      |> Map.put("targets", [
        %{
          "model" => "ollama/live-test",
          "context_window" => 256,
          "provider_base_url" => base_url
        }
      ])
      |> Map.put("governance", [])
      |> Map.put("stream_rules", [
        %{
          "id" => "ollama-stream-reminder-retry",
          "contains" => "OldClient(",
          "action" => "retry_with_reminder",
          "reminder" => "Use NewClient instead.",
          "max_retries" => 1
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/chat/completions", %{
        model: "unit-model",
        stream: true,
        messages: [%{role: "user", content: "stream code"}]
      })

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    assert conn.resp_body =~ "NewClient("
    refute conn.resp_body =~ "OldClient("

    [receipt_id] = get_resp_header(conn, "x-wardwright-receipt-id")

    receipt = Wardwright.ReceiptStore.get(receipt_id)
    stream_policy = get_in(receipt, ["final", "stream_policy"])

    assert stream_policy["retry_count"] == 1
    assert stream_policy["released_to_consumer"] == true
    assert get_in(receipt, ["final", "provider_metadata", "stream_format"]) == "ollama_ndjson"
    assert get_in(receipt, ["final", "provider_metadata", "done"]) == true
    assert get_in(receipt, ["final", "provider_metadata", "done_reason"]) == "stop"
    assert get_in(receipt, ["final", "provider_metadata", "prompt_eval_count"]) == 4

    assert get_in(receipt, ["attempts", Access.at(0), "provider_metadata", "done_reason"]) ==
             "stop"

    assert [
             %{"status" => "stream_policy_retry_required", "released_to_consumer" => false},
             %{"status" => "completed", "released_to_consumer" => true}
           ] = stream_policy["attempts"]

    assert Enum.any?(stream_policy["events"], fn event ->
             event["type"] == "attempt.retry_requested" and
               event["rule_id"] == "ollama-stream-reminder-retry" and
               event["reminder"] == "Use NewClient instead." and
               event["reminder_injected"] == true
           end)
  end

  test "ollama stream targets release bounded safe bytes before cancelling on a later trigger" do
    base_url = streaming_provider_base_url("/ollama")

    config =
      unit_policy_config()
      |> Map.put("targets", [
        %{
          "model" => "ollama/live-test",
          "context_window" => 256,
          "provider_base_url" => base_url
        }
      ])
      |> Map.put("governance", [])
      |> Map.put("stream_rules", [
        %{
          "id" => "ollama-bounded-stream-block",
          "contains" => "OldClient(",
          "action" => "block",
          "horizon_bytes" => byte_size("OldClient(")
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/chat/completions", %{
        model: "unit-model",
        stream: true,
        messages: [%{role: "user", content: "stream safe prefix code"}]
      })

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    assert conn.resp_body =~ "safe prefix"
    assert conn.resp_body =~ "stream_policy_blocked"
    refute conn.resp_body =~ "OldClient("

    [receipt_id] = get_resp_header(conn, "x-wardwright-receipt-id")

    stream_policy =
      receipt_id |> Wardwright.ReceiptStore.get() |> get_in(["final", "stream_policy"])

    assert stream_policy["status"] == "stream_policy_blocked"
    assert stream_policy["released_bytes"] > 0

    assert [
             %{
               "called_provider" => true,
               "mock" => false,
               "provider_status" => provider_status
             }
           ] = stream_policy["attempts"]

    assert provider_status in ["cancelled", "provider_error", "completed"]
  end

  test "openai-compatible stream targets parse SSE deltas from provider HTTP chunks" do
    base_url = streaming_provider_base_url("/openai")
    System.put_env("WARDWRIGHT_ALLOW_TEST_CREDENTIALS", "1")
    System.put_env("WARDWRIGHT_TEST_OPENAI_KEY", "test-openai-key")

    on_exit(fn ->
      System.delete_env("WARDWRIGHT_ALLOW_TEST_CREDENTIALS")
      System.delete_env("WARDWRIGHT_TEST_OPENAI_KEY")
    end)

    config =
      unit_policy_config()
      |> Map.put("targets", [
        %{
          "model" => "openai-compatible/live-test",
          "context_window" => 256,
          "provider_kind" => "openai-compatible",
          "provider_base_url" => base_url,
          "credential_env" => "WARDWRIGHT_TEST_OPENAI_KEY"
        }
      ])
      |> Map.put("governance", [])
      |> Map.put("stream_rules", [])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/chat/completions", %{
        model: "unit-model",
        stream: true,
        messages: [%{role: "user", content: "stream code"}]
      })

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    assert conn.resp_body =~ "hello "
    assert conn.resp_body =~ "world"

    indexes =
      conn.resp_body
      |> String.split("\n\n", trim: true)
      |> Enum.map(&(&1 |> String.trim_leading("data:") |> String.trim()))
      |> Enum.reject(&(&1 == "[DONE]"))
      |> Enum.map(&Jason.decode!/1)
      |> Enum.map(&get_in(&1, ["choices", Access.at(0), "index"]))

    assert indexes == [0, 0]

    [receipt_id] = get_resp_header(conn, "x-wardwright-receipt-id")
    receipt = Wardwright.ReceiptStore.get(receipt_id)

    assert get_in(receipt, ["attempts", Access.at(0), "called_provider"]) == true
    assert get_in(receipt, ["attempts", Access.at(0), "mock"]) == false
    assert get_in(receipt, ["final", "stream_policy", "released_to_consumer"]) == true
    assert get_in(receipt, ["final", "provider_metadata", "stream_format"]) == "openai_sse"
    assert get_in(receipt, ["final", "provider_metadata", "finish_reason"]) == "stop"
    assert get_in(receipt, ["final", "provider_metadata", "done"]) == true
    assert get_in(receipt, ["final", "provider_metadata", "usage", "total_tokens"]) == 5

    assert get_in(receipt, ["attempts", Access.at(0), "provider_metadata", "finish_reason"]) ==
             "stop"
  end

  test "openai-compatible targets fail loudly instead of dropping tool request fields" do
    System.put_env("WARDWRIGHT_ALLOW_TEST_CREDENTIALS", "1")

    on_exit(fn ->
      System.delete_env("WARDWRIGHT_ALLOW_TEST_CREDENTIALS")
    end)

    config =
      unit_policy_config()
      |> Map.put("targets", [
        %{
          "model" => "openai-compatible/live-test",
          "context_window" => 256,
          "provider_kind" => "openai-compatible",
          "provider_base_url" => "http://127.0.0.1:9",
          "credential_env" => "WARDWRIGHT_TEST_OPENAI_KEY"
        }
      ])
      |> Map.put("governance", [])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/chat/completions", %{
        model: "unit-model",
        tools: [
          %{
            type: "function",
            function: %{name: "create_pull_request", parameters: %{type: "object"}}
          }
        ],
        tool_choice: "auto",
        messages: [
          %{role: "user", content: "prepare a pull request"},
          %{
            role: "assistant",
            content: nil,
            tool_calls: [
              %{
                id: "call_1",
                type: "function",
                function: %{name: "create_pull_request", arguments: "{}"}
              }
            ]
          },
          %{role: "tool", tool_call_id: "call_1", content: "created"}
        ]
      })

    assert conn.status == 502

    body = Jason.decode!(conn.resp_body)
    assert get_in(body, ["wardwright", "status"]) == "provider_error"
    assert get_in(body, ["wardwright", "provider_error"]) =~ "does not support request fields"
    assert get_in(body, ["wardwright", "provider_error"]) =~ "tools"
    assert get_in(body, ["wardwright", "provider_error"]) =~ "tool_choice"
    assert get_in(body, ["wardwright", "provider_error"]) =~ "message.tool_calls"
    assert get_in(body, ["wardwright", "provider_error"]) =~ "message.tool_call_id"
    assert get_in(body, ["wardwright", "provider_error"]) =~ "message.role:tool"

    [receipt_id] = get_resp_header(conn, "x-wardwright-receipt-id")
    receipt = Wardwright.ReceiptStore.get(receipt_id)

    assert get_in(receipt, ["attempts", Access.at(0), "called_provider"]) == false

    assert get_in(receipt, ["attempts", Access.at(0), "provider_error"]) =~
             "does not support request fields"
  end
end
