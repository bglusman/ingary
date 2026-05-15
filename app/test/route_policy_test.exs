defmodule Wardwright.RoutePolicyTest do
  use Wardwright.RouterCase

  test "route gate policy constrains planner candidates before provider selection" do
    config =
      unit_policy_config()
      |> Map.put("targets", [
        %{"model" => "local/qwen", "context_window" => 32},
        %{"model" => "managed/kimi", "context_window" => 256}
      ])
      |> Map.put("governance", [
        %{
          "id" => "private-local-only",
          "kind" => "route_gate",
          "action" => "restrict_routes",
          "contains" => "private",
          "allowed_targets" => ["local"],
          "message" => "private context must stay local"
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/synthetic/simulate", %{
        request: %{
          model: "unit-model",
          messages: [%{role: "user", content: "private notes, summarize briefly"}]
        }
      })

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert get_in(body, ["receipt", "decision", "selected_model"]) == "local/qwen"

    assert get_in(body, ["receipt", "decision", "policy_route_constraints"]) == %{
             "allowed_targets" => ["local"]
           }

    assert [
             %{
               "rule_id" => "private-local-only",
               "kind" => "route_gate",
               "action" => "restrict_routes",
               "allowed_targets" => ["local"]
             }
           ] = get_in(body, ["receipt", "decision", "policy_actions"])
  end

  test "route gate policy fails closed when it removes every provider candidate" do
    config =
      unit_policy_config()
      |> Map.put("governance", [
        %{
          "id" => "impossible-route",
          "kind" => "route_gate",
          "action" => "restrict_routes",
          "contains" => "private",
          "allowed_targets" => ["nonexistent-provider"]
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/chat/completions", %{
        model: "unit-model",
        messages: [%{role: "user", content: "private"}]
      })

    assert conn.status == 429
    body = Jason.decode!(conn.resp_body)

    assert get_in(body, ["wardwright", "status"]) == "policy_failed_closed"
    receipt = body |> get_in(["wardwright", "receipt_id"]) |> Wardwright.ReceiptStore.get()

    assert get_in(receipt, ["decision", "route_blocked"]) == true
    assert get_in(receipt, ["decision", "selected_model"]) == "unconfigured/no-target"

    assert get_in(receipt, ["decision", "policy_route_constraints"]) == %{
             "allowed_targets" => ["nonexistent-provider"]
           }
  end

  test "route gate policy can force a specific model through a route override" do
    config =
      unit_policy_config()
      |> Map.put("governance", [
        %{
          "id" => "deep-reasoning",
          "kind" => "route_gate",
          "action" => "switch_model",
          "contains" => "hard proof",
          "target_model" => "large/model",
          "message" => "use the strongest configured model"
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/synthetic/simulate", %{
        request: %{
          model: "unit-model",
          messages: [%{role: "user", content: "hard proof"}]
        }
      })

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert get_in(body, ["receipt", "decision", "route_type"]) == "policy_override"
    assert get_in(body, ["receipt", "decision", "selected_model"]) == "large/model"

    assert get_in(body, ["receipt", "decision", "policy_route_constraints"]) == %{
             "forced_model" => "large/model"
           }
  end

  test "route override fails closed when the forced model is unavailable" do
    config =
      unit_policy_config()
      |> Map.put("governance", [
        %{
          "id" => "missing-model",
          "kind" => "route_gate",
          "action" => "switch_model",
          "contains" => "hard proof",
          "target_model" => "missing/model"
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/chat/completions", %{
        model: "unit-model",
        messages: [%{role: "user", content: "hard proof " <> String.duplicate("x", 60)}]
      })

    assert conn.status == 429
    body = Jason.decode!(conn.resp_body)
    assert get_in(body, ["wardwright", "status"]) == "policy_failed_closed"

    receipt = body |> get_in(["wardwright", "receipt_id"]) |> Wardwright.ReceiptStore.get()
    assert get_in(receipt, ["decision", "route_blocked"]) == true
    assert get_in(receipt, ["decision", "fallback_used"]) == false

    assert get_in(receipt, ["decision", "reason"]) ==
             "policy forced model was not in the allowed route set"
  end

  test "route override only falls back when explicitly allowed" do
    config =
      unit_policy_config()
      |> Map.put("governance", [
        %{
          "id" => "missing-model",
          "kind" => "route_gate",
          "action" => "switch_model",
          "contains" => "hard proof",
          "target_model" => "missing/model",
          "allow_fallback" => true
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/chat/completions", %{
        model: "unit-model",
        messages: [%{role: "user", content: "hard proof " <> String.duplicate("x", 60)}]
      })

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert get_in(body, ["wardwright", "status"]) == "completed"

    receipt = body |> get_in(["wardwright", "receipt_id"]) |> Wardwright.ReceiptStore.get()

    assert get_in(receipt, ["decision", "route_type"]) == "policy_override_fallback"
    assert get_in(receipt, ["decision", "fallback_used"]) == true
    assert get_in(receipt, ["decision", "route_blocked"]) == false
    assert get_in(receipt, ["decision", "selected_model"]) == "medium/model"

    assert get_in(receipt, ["decision", "policy_route_constraints"]) == %{
             "forced_model" => "missing/model",
             "allow_fallback" => true
           }

    refute Enum.any?(
             get_in(receipt, ["decision", "skipped"]),
             &match?(%{"target" => "medium/model", "reason" => "policy_route_gate"}, &1)
           )

    assert Enum.any?(
             get_in(receipt, ["decision", "skipped"]),
             &match?(%{"target" => "missing/model", "reason" => "forced_model_unavailable"}, &1)
           )

    assert Enum.any?(
             get_in(receipt, ["decision", "skipped"]),
             &match?(%{"target" => "tiny/model", "reason" => "context_window_too_small"}, &1)
           )
  end

  test "route override fails closed when the forced model cannot fit the prompt" do
    config =
      unit_policy_config()
      |> Map.put("governance", [
        %{
          "id" => "too-small-model",
          "kind" => "route_gate",
          "action" => "switch_model",
          "contains" => "long proof",
          "target_model" => "tiny/model"
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/chat/completions", %{
        model: "unit-model",
        messages: [%{role: "user", content: "long proof " <> String.duplicate("x", 200)}]
      })

    assert conn.status == 429
    body = Jason.decode!(conn.resp_body)

    receipt = body |> get_in(["wardwright", "receipt_id"]) |> Wardwright.ReceiptStore.get()
    assert get_in(receipt, ["decision", "route_blocked"]) == true

    assert get_in(receipt, ["decision", "reason"]) ==
             "policy forced model was too small for estimated prompt"

    assert [%{"target" => "tiny/model", "reason" => "context_window_too_small"} | _] =
             get_in(receipt, ["decision", "skipped"])
  end

  test "Dune policy engine can return route constraints used by the planner" do
    config =
      unit_policy_config()
      |> Map.put("targets", [
        %{"model" => "local/qwen", "context_window" => 32},
        %{"model" => "managed/kimi", "context_window" => 256}
      ])
      |> Map.put("governance", [
        %{
          "id" => "dune-route-gate",
          "kind" => "route_gate",
          "engine" => "dune",
          "source" =>
            ~s(%{"action" => "restrict_routes", "allowed_targets" => ["local"], "reason" => "private route gate"})
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/synthetic/simulate", %{
        request: %{
          model: "unit-model",
          messages: [%{role: "user", content: "small request"}]
        }
      })

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert get_in(body, ["receipt", "decision", "selected_model"]) == "local/qwen"

    assert get_in(body, ["receipt", "decision", "policy_route_constraints"]) == %{
             "allowed_targets" => ["local"]
           }

    assert [%{"rule_id" => "dune-route-gate", "action" => "restrict_routes"}] =
             get_in(body, ["receipt", "decision", "policy_actions"])

    assert [
             %{
               "action_schema" => "wardwright.policy_action.v1",
               "phase" => "request.routing",
               "effect_type" => "route_constraint",
               "source" => %{"type" => "engine", "engine" => "dune", "status" => "ok"},
               "conflict_key" => "route_constraints",
               "conflict_policy" => "ordered"
             }
           ] = get_in(body, ["receipt", "decision", "policy_actions"])
  end

  test "route-affecting policy actions expose ordered conflict metadata" do
    config =
      unit_policy_config()
      |> Map.put("targets", [
        %{"model" => "local/qwen", "context_window" => 32},
        %{"model" => "managed/kimi", "context_window" => 256}
      ])
      |> Map.put("governance", [
        %{
          "id" => "private-local-provider",
          "kind" => "route_gate",
          "action" => "restrict_routes",
          "contains" => "private",
          "allowed_targets" => ["local"]
        },
        %{
          "id" => "private-specific-model",
          "kind" => "route_gate",
          "action" => "switch_model",
          "contains" => "private",
          "target_model" => "local/qwen"
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/synthetic/simulate", %{
        request: %{
          model: "unit-model",
          messages: [%{role: "user", content: "private working notes"}]
        }
      })

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert get_in(body, ["receipt", "decision", "policy_route_constraints"]) == %{
             "allowed_targets" => ["local"],
             "forced_model" => "local/qwen"
           }

    assert [
             %{
               "conflict_schema" => "wardwright.policy_conflict.v1",
               "key" => "route_constraints",
               "class" => "ordered",
               "rule_ids" => ["private-local-provider", "private-specific-model"],
               "required_resolution" => "preserve policy declaration order"
             }
           ] = get_in(body, ["receipt", "decision", "policy_conflicts"])
  end
end
