defmodule Wardwright.HybridPolicyEngineTest do
  use Wardwright.RouterCase

  test "hybrid policy engine propagates nested blocking actions" do
    config =
      unit_policy_config()
      |> Map.put("governance", [
        %{
          "id" => "hybrid-block",
          "kind" => "route_gate",
          "engine" => "hybrid",
          "engines" => [
            %{
              "engine" => "primitive",
              "rules" => [
                %{"id" => "primitive-deny", "contains" => "deny me", "action" => "block"}
              ]
            }
          ]
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/chat/completions", %{
        model: "unit-model",
        messages: [%{role: "user", content: "please deny me"}]
      })

    assert conn.status == 429
    body = Jason.decode!(conn.resp_body)
    receipt = body |> get_in(["wardwright", "receipt_id"]) |> Wardwright.ReceiptStore.get()

    assert [
             %{
               "action_schema" => "wardwright.policy_action.v1",
               "rule_id" => "primitive-deny",
               "kind" => "route_gate",
               "action" => "block",
               "effect_type" => "terminal",
               "conflict_key" => "terminal_decision"
             }
           ] = get_in(receipt, ["decision", "policy_actions"])
  end

  test "hybrid policy reports policy blocks separately from engine failures" do
    assert %{
             "engine" => "hybrid",
             "result_schema" => "wardwright.policy_result.v1",
             "status" => "ok",
             "action" => "block",
             "actions" => [
               %{
                 "action_schema" => "wardwright.policy_action.v1",
                 "rule_id" => "primitive-deny",
                 "action" => "block",
                 "effect_type" => "terminal"
               }
             ]
           } =
             Wardwright.Policy.Engine.evaluate(
               %{
                 "engine" => "hybrid",
                 "engines" => [
                   %{
                     "engine" => "primitive",
                     "rules" => [
                       %{"id" => "primitive-deny", "contains" => "deny me", "action" => "block"}
                     ]
                   }
                 ]
               },
               %{"request_text" => "please deny me"}
             )
  end

  test "policy engine errors fail closed before provider invocation" do
    config =
      unit_policy_config()
      |> Map.put("governance", [
        %{
          "id" => "unavailable-wasm-policy",
          "kind" => "route_gate",
          "engine" => "wasm"
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/chat/completions", %{
        model: "unit-model",
        messages: [%{role: "user", content: "hello"}]
      })

    assert conn.status == 429
    body = Jason.decode!(conn.resp_body)

    assert get_in(body, ["wardwright", "status"]) == "policy_failed_closed"
    receipt = body |> get_in(["wardwright", "receipt_id"]) |> Wardwright.ReceiptStore.get()

    assert [
             %{
               "rule_id" => "unavailable-wasm-policy",
               "kind" => "route_gate",
               "action" => "block"
             }
           ] = get_in(receipt, ["decision", "policy_actions"])
  end
end
