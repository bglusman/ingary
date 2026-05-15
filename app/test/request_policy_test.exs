defmodule Wardwright.RequestPolicyTest do
  use Wardwright.RouterCase

  test "request policy records asynchronous alert events" do
    config = unit_policy_config()
    assert call(:post, "/__test/config", config).status == 200

    request = %{
      request: %{
        model: "wardwright/unit-model",
        messages: [%{role: "user", content: "Looks done; return JSON for the caller"}]
      }
    }

    conn = call(:post, "/v1/synthetic/simulate", request)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert get_in(body, ["receipt", "final", "alert_count"]) == 1

    assert [%{"type" => "policy.alert", "rule_id" => "ambiguous-success"}] =
             get_in(body, ["receipt", "final", "events"])

    assert [%{"rule_id" => "ambiguous-success", "matched" => true}] =
             get_in(body, ["receipt", "decision", "policy_actions"])
  end

  test "request transform policy injects a named reminder into the prompt" do
    config =
      unit_policy_config()
      |> Map.put("governance", [
        %{
          "id" => "json-reminder",
          "kind" => "request_transform",
          "action" => "inject_reminder_and_retry",
          "contains" => "return json",
          "reminder" => "Return only valid JSON."
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/synthetic/simulate", %{
        request: %{
          model: "unit-model",
          messages: [%{role: "user", content: "Please return JSON."}]
        }
      })

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert get_in(body, ["receipt", "request", "message_count"]) == 2

    assert [
             %{
               "rule_id" => "json-reminder",
               "matched" => true,
               "reminder_injected" => true
             }
           ] = get_in(body, ["receipt", "decision", "policy_actions"])
  end
end
