defmodule Wardwright.AlertDeliveryPolicyTest do
  use Wardwright.RouterCase

  test "alert delivery backpressure can fail closed before provider invocation" do
    config =
      unit_policy_config()
      |> Map.put("alert_delivery", %{"capacity" => 0, "on_full" => "fail_closed"})
      |> Map.put("governance", [
        %{
          "id" => "always-alert",
          "kind" => "request_guard",
          "action" => "alert_async",
          "contains" => "alert me",
          "message" => "alert queue full"
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/chat/completions", %{
        model: "unit-model",
        messages: [%{role: "user", content: "alert me"}]
      })

    assert conn.status == 429
    body = Jason.decode!(conn.resp_body)
    assert get_in(body, ["wardwright", "status"]) == "policy_failed_closed"
    assert [%{"outcome" => "failed_closed"}] = get_in(body, ["wardwright", "alert_delivery"])
  end

  test "successful alert delivery records queued receipts without failing closed" do
    config =
      unit_policy_config()
      |> Map.put("alert_delivery", %{"capacity" => 4, "on_full" => "fail_closed"})
      |> Map.put("governance", [
        %{
          "id" => "always-alert",
          "kind" => "request_guard",
          "action" => "alert_async",
          "contains" => "alert me",
          "message" => "operator review requested",
          "severity" => "warning"
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/chat/completions", %{
        model: "unit-model",
        messages: [%{role: "user", content: "alert me"}]
      })

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert [
             %{
               "outcome" => "queued",
               "rule_id" => "always-alert",
               "idempotency_key" => ":always-alert:operator review requested:warning"
             }
           ] = get_in(body, ["wardwright", "alert_delivery"])

    receipt = body |> get_in(["wardwright", "receipt_id"]) |> Wardwright.ReceiptStore.get()

    assert [
             %{
               "type" => "policy.alert",
               "rule_id" => "always-alert",
               "message" => "operator review requested",
               "severity" => "warning"
             }
           ] = get_in(receipt, ["final", "events"])
  end

  test "alert delivery exposes queue health and publishes delivery events" do
    Wardwright.Policy.AlertDelivery.configure(%{"capacity" => 1, "on_full" => "dead_letter"})
    assert :ok = Wardwright.Runtime.Events.subscribe(Wardwright.Runtime.Events.topic(:policies))

    results =
      Wardwright.Policy.AlertDelivery.deliver([
        %{
          "type" => "policy.alert",
          "rule_id" => "first-alert",
          "message" => "first",
          "severity" => "warning"
        },
        %{
          "type" => "policy.alert",
          "rule_id" => "second-alert",
          "message" => "second",
          "severity" => "warning"
        }
      ])

    assert [%{"outcome" => "queued"}, %{"outcome" => "dead_lettered"}] = results

    assert %{
             "kind" => "in_memory_alert_sink",
             "capacity" => 1,
             "on_full" => "dead_letter",
             "queue_depth" => 1,
             "queued_count" => 1,
             "dead_letter_count" => 1,
             "last_result" => %{"rule_id" => "second-alert", "outcome" => "dead_lettered"}
           } = Wardwright.Policy.AlertDelivery.status()

    assert_receive {:wardwright_runtime_event, "runtime:policies",
                    %{
                      "type" => "policy_alert.delivery",
                      "rule_id" => "first-alert",
                      "outcome" => "queued",
                      "queue_depth" => 1,
                      "capacity" => 1
                    }}

    assert_receive {:wardwright_runtime_event, "runtime:policies",
                    %{
                      "type" => "policy_alert.delivery",
                      "rule_id" => "second-alert",
                      "outcome" => "dead_lettered",
                      "queue_depth" => 1,
                      "capacity" => 1
                    }}
  end

  test "admin policy alert status is protected and exposes sink health" do
    assert call(:get, "/admin/policy-alerts", nil, [], {203, 0, 113, 10}).status == 403

    conn = call(:get, "/admin/policy-alerts")
    assert conn.status == 200
    assert %{"kind" => "in_memory_alert_sink", "queue_depth" => 0} = Jason.decode!(conn.resp_body)
  end

  test "alert fail-closed blocks streaming and simulation paths consistently" do
    config =
      unit_policy_config()
      |> Map.put("alert_delivery", %{"capacity" => 0, "on_full" => "fail_closed"})
      |> Map.put("governance", [
        %{
          "id" => "stream-alert",
          "kind" => "request_guard",
          "action" => "alert_async",
          "contains" => "alert me"
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    stream =
      call(:post, "/v1/chat/completions", %{
        model: "unit-model",
        stream: true,
        messages: [%{role: "user", content: "alert me"}]
      })

    assert stream.status == 429
    assert get_resp_header(stream, "content-type") == ["application/json; charset=utf-8"]

    assert get_in(Jason.decode!(stream.resp_body), ["wardwright", "status"]) ==
             "policy_failed_closed"

    assert call(:post, "/__test/config", config).status == 200

    simulated =
      call(:post, "/v1/synthetic/simulate", %{
        request: %{
          model: "unit-model",
          messages: [%{role: "user", content: "alert me"}]
        }
      })

    assert simulated.status == 200

    assert get_in(Jason.decode!(simulated.resp_body), ["receipt", "final", "status"]) ==
             "policy_failed_closed"
  end
end
