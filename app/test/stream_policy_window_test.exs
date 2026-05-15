defmodule Wardwright.StreamPolicyWindowTest do
  use Wardwright.RouterCase

  test "stream policy rewrites matched chunks before release and records receipt evidence" do
    config =
      unit_policy_config()
      |> Map.put("stream_rules", [
        %{
          "id" => "deprecated-client",
          "contains" => "OldClient(",
          "action" => "rewrite_chunk",
          "replacement" => "NewClient("
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/chat/completions", %{
        model: "unit-model",
        stream: true,
        metadata: %{"mock_stream_chunks" => ["use OldClient(", "arg) now"]},
        messages: [%{role: "user", content: "stream code"}]
      })

    assert conn.status == 200
    assert conn.resp_body =~ "NewClient("
    refute conn.resp_body =~ "OldClient("

    [receipt_id] = get_resp_header(conn, "x-wardwright-receipt-id")
    receipt = Wardwright.ReceiptStore.get(receipt_id)

    assert get_in(receipt, ["final", "stream_trigger_count"]) == 1
    assert get_in(receipt, ["final", "stream_policy_action"]) == "rewrite_chunk"
    assert get_in(receipt, ["final", "stream_policy", "released_to_consumer"]) == true

    assert [
             %{
               "rule_id" => "deprecated-client",
               "action" => "rewrite_chunk",
               "chunk_index" => 0
             }
           ] = get_in(receipt, ["final", "stream_policy", "events"])
  end

  test "stream policy block returns fail-closed JSON instead of SSE" do
    config =
      unit_policy_config()
      |> Map.put("stream_rules", [
        %{
          "id" => "secret-stream",
          "regex" => "secret-[0-9]+",
          "action" => "block"
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/chat/completions", %{
        model: "unit-model",
        stream: true,
        metadata: %{"mock_stream_chunks" => ["safe prefix ", "secret-123"]},
        messages: [%{role: "user", content: "stream code"}]
      })

    assert conn.status == 422
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

    body = Jason.decode!(conn.resp_body)
    assert get_in(body, ["wardwright", "status"]) == "stream_policy_blocked"
    assert get_in(body, ["wardwright", "selected_model"]) == "tiny/model"
    assert get_in(body, ["wardwright", "stream_policy", "released_to_consumer"]) == false
    assert get_in(body, ["wardwright", "stream_policy", "generated_bytes"]) > 0
    assert get_in(body, ["wardwright", "stream_policy", "held_bytes"]) > 0
    assert get_in(body, ["wardwright", "stream_policy", "released_bytes"]) == 0

    [receipt_id] = get_resp_header(conn, "x-wardwright-receipt-id")
    receipt = Wardwright.ReceiptStore.get(receipt_id)

    assert get_in(receipt, ["final", "stream_policy", "released_to_consumer"]) == false
    assert get_in(receipt, ["final", "stream_policy", "released_bytes"]) == 0

    assert get_in(receipt, ["final", "stream_policy", "events", Access.at(0), "rule_id"]) ==
             "secret-stream"
  end

  test "stream policy detects terminal regex matches split across chunks before release" do
    config =
      unit_policy_config()
      |> Map.put("stream_rules", [
        %{
          "id" => "split-secret-stream",
          "regex" => "secret-[0-9]+",
          "action" => "block"
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/chat/completions", %{
        model: "unit-model",
        stream: true,
        metadata: %{"mock_stream_chunks" => ["safe prefix sec", "ret-123 suffix"]},
        messages: [%{role: "user", content: "stream code"}]
      })

    assert conn.status == 422
    refute conn.resp_body =~ "text/event-stream"

    body = Jason.decode!(conn.resp_body)
    assert get_in(body, ["wardwright", "status"]) == "stream_policy_blocked"
    assert get_in(body, ["wardwright", "stream_policy", "released_to_consumer"]) == false
    assert get_in(body, ["wardwright", "stream_policy", "trigger_count"]) == 1
    assert get_in(body, ["wardwright", "stream_policy", "released_bytes"]) == 0

    assert [
             %{
               "rule_id" => "split-secret-stream",
               "action" => "block",
               "chunk_index" => 1,
               "match_scope" => "stream_window"
             }
           ] = get_in(body, ["wardwright", "stream_policy", "events"])
  end

  test "stream policy retry split-window matches keep pre-trigger bytes unreleased" do
    config =
      unit_policy_config()
      |> Map.put("stream_rules", [
        %{
          "id" => "split-retry-unreleased",
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
        metadata: %{"mock_stream_chunks" => ["safe prefix Old", "Client(arg)"]},
        messages: [%{role: "user", content: "stream code"}]
      })

    assert conn.status == 409

    body = Jason.decode!(conn.resp_body)
    stream_policy = get_in(body, ["wardwright", "stream_policy"])

    assert stream_policy["released_to_consumer"] == false
    assert stream_policy["released_bytes"] == 0
    assert stream_policy["held_bytes"] > 0

    assert [
             %{
               "status" => "stream_policy_retry_required",
               "released_to_consumer" => false,
               "released_bytes" => 0
             }
           ] = stream_policy["attempts"]
  end

  test "stream policy bounded horizon releases old safe bytes while retaining split triggers" do
    result =
      Wardwright.Policy.Stream.evaluate(
        ["safe prefix that can release ", "Old", "Client(arg) now"],
        [
          %{
            "id" => "bounded-deprecated-client",
            "contains" => "OldClient(",
            "action" => "block",
            "horizon_bytes" => byte_size("OldClient(")
          }
        ]
      )

    assert result.status == "stream_policy_blocked"
    assert result.released_bytes > 0
    assert result.held_bytes > byte_size("OldClient(")
    assert result.blocked_bytes == result.held_bytes

    released = Enum.join(result.chunks)
    assert released != ""
    refute released =~ "Old"
    refute released =~ "Client("

    assert [
             %{
               "rule_id" => "bounded-deprecated-client",
               "action" => "block",
               "match_scope" => "stream_window"
             }
           ] = result.events
  end

  test "stream policy trigger events include literal match offsets across split chunks" do
    result =
      Wardwright.Policy.Stream.evaluate(
        ["abc Old", "Client("],
        [
          %{
            "id" => "offset-split-literal",
            "contains" => "OldClient(",
            "action" => "block",
            "horizon_bytes" => byte_size("OldClient(")
          }
        ]
      )

    assert result.status == "stream_policy_blocked"

    assert [
             %{
               "type" => "stream_policy.triggered",
               "rule_id" => "offset-split-literal",
               "action" => "block",
               "chunk_index" => 1,
               "match_scope" => "stream_window",
               "match_kind" => "literal",
               "chunk_start_byte" => 7,
               "chunk_end_byte" => 14,
               "stream_window_start_byte" => 0,
               "stream_window_end_byte" => 14,
               "match_start_byte" => 4,
               "match_end_byte" => 14
             }
           ] = result.events
  end

  test "stream policy trigger events include regex match offsets across split chunks" do
    result =
      Wardwright.Policy.Stream.evaluate(
        ["abc Old", "Client("],
        [
          %{
            "id" => "offset-split-regex",
            "regex" => "OldClient\\(",
            "action" => "block",
            "horizon_bytes" => byte_size("OldClient(")
          }
        ]
      )

    assert result.status == "stream_policy_blocked"

    assert [
             %{
               "type" => "stream_policy.triggered",
               "rule_id" => "offset-split-regex",
               "action" => "block",
               "chunk_index" => 1,
               "match_scope" => "stream_window",
               "match_kind" => "regex",
               "chunk_start_byte" => 7,
               "chunk_end_byte" => 14,
               "stream_window_start_byte" => 0,
               "stream_window_end_byte" => 14,
               "match_start_byte" => 4,
               "match_end_byte" => 14
             }
           ] = result.events
  end

  test "stream policy offsets stay coherent after earlier rewrites change byte length" do
    result =
      Wardwright.Policy.Stream.evaluate(
        ["ABC", "TAIL"],
        [
          %{
            "id" => "length-changing-rewrite",
            "contains" => "ABC",
            "action" => "rewrite_chunk",
            "replacement" => "LONGER-REPLACEMENT"
          },
          %{
            "id" => "post-rewrite-window",
            "contains" => "REPLACEMENTTAIL",
            "action" => "block"
          }
        ]
      )

    assert result.status == "stream_policy_blocked"

    assert [
             %{
               "rule_id" => "length-changing-rewrite",
               "match_scope" => "chunk",
               "match_start_byte" => 0,
               "match_end_byte" => 3
             },
             %{
               "rule_id" => "post-rewrite-window",
               "match_scope" => "stream_window",
               "chunk_start_byte" => 18,
               "chunk_end_byte" => 22,
               "stream_window_start_byte" => 0,
               "stream_window_end_byte" => 22,
               "match_start_byte" => 7,
               "match_end_byte" => 22
             }
           ] = result.events
  end
end
