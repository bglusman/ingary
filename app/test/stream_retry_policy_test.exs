defmodule Wardwright.StreamRetryPolicyTest do
  use Wardwright.RouterCase

  test "stream policy retry_with_reminder restarts generation before release" do
    config =
      unit_policy_config()
      |> Map.put("targets", [
        %{"model" => "large/model", "context_window" => 256}
      ])
      |> Map.put("stream_rules", [
        %{
          "id" => "deprecated-client-retry",
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
        metadata: %{
          "mock_stream_attempt_chunks" => [
            ["use OldClient(", "arg) now"],
            ["use NewClient(", "arg) now"]
          ]
        },
        messages: [%{role: "user", content: "stream code"}]
      })

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    assert conn.resp_body =~ "NewClient("
    refute conn.resp_body =~ "OldClient("

    [receipt_id] = get_resp_header(conn, "x-wardwright-receipt-id")
    receipt = Wardwright.ReceiptStore.get(receipt_id)
    stream_policy = get_in(receipt, ["final", "stream_policy"])

    assert stream_policy["status"] == "completed"
    assert stream_policy["retry_count"] == 1
    assert stream_policy["max_retries"] == 1
    assert stream_policy["released_to_consumer"] == true
    assert stream_policy["released_bytes"] > 0
    assert stream_policy["held_bytes"] == 0

    assert [
             %{
               "status" => "stream_policy_retry_required",
               "released_to_consumer" => false,
               "generated_bytes" => generated_bytes,
               "held_bytes" => held_bytes
             },
             %{"status" => "completed", "released_to_consumer" => true}
           ] = stream_policy["attempts"]

    assert held_bytes > 0
    assert generated_bytes > 0

    assert [
             %{
               "type" => "stream_policy.triggered",
               "rule_id" => "deprecated-client-retry",
               "action" => "retry_with_reminder"
             },
             %{
               "type" => "attempt.retry_requested",
               "rule_id" => "deprecated-client-retry",
               "retry_count" => 1,
               "reminder" => "Use NewClient instead."
             }
           ] = stream_policy["events"]
  end

  test "stream policy retry calls the selected provider again before releasing bytes" do
    config =
      unit_policy_config()
      |> Map.put("targets", [
        %{
          "model" => "canned/model",
          "context_window" => 256,
          "provider_kind" => "canned_sequence",
          "canned_stream_attempt_chunks" => [
            ["use Old", "Client(arg) now"],
            ["use NewClient(", "arg) now"]
          ]
        }
      ])
      |> Map.put("governance", [])
      |> Map.put("stream_rules", [
        %{
          "id" => "deprecated-client-provider-retry",
          "contains" => "OldClient(",
          "action" => "retry_with_reminder",
          "reminder" => "Use NewClient instead.",
          "max_retries" => 1
        }
      ])

    assert :ok = Wardwright.Runtime.Events.subscribe(Wardwright.Runtime.Events.topic(:models))
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

    stream_policy =
      receipt_id |> Wardwright.ReceiptStore.get() |> get_in(["final", "stream_policy"])

    assert stream_policy["status"] == "completed"
    assert stream_policy["retry_count"] == 1
    assert stream_policy["released_to_consumer"] == true

    assert [
             %{
               "attempt_index" => 0,
               "status" => "stream_policy_retry_required",
               "called_provider" => true,
               "mock" => false,
               "provider_status" => "cancelled",
               "released_to_consumer" => false
             },
             %{
               "attempt_index" => 1,
               "status" => "completed",
               "called_provider" => true,
               "mock" => false,
               "provider_status" => "completed",
               "released_to_consumer" => true
             }
           ] = stream_policy["attempts"]

    assert_receive {:wardwright_runtime_event, "runtime:models",
                    %{
                      "type" => "provider.attempt.started",
                      "provider_id" => "canned",
                      "model" => "canned/model",
                      "stream" => true
                    }}

    assert_receive {:wardwright_runtime_event, "runtime:models",
                    %{
                      "type" => "provider.attempt.finished",
                      "provider_id" => "canned",
                      "model" => "canned/model",
                      "status" => "cancelled"
                    }}

    assert_receive {:wardwright_runtime_event, "runtime:models",
                    %{
                      "type" => "provider.attempt.started",
                      "provider_id" => "canned",
                      "model" => "canned/model",
                      "stream" => true
                    }}

    assert_receive {:wardwright_runtime_event, "runtime:models",
                    %{
                      "type" => "provider.attempt.finished",
                      "provider_id" => "canned",
                      "model" => "canned/model",
                      "status" => "completed"
                    }}
  end
end
