defmodule Wardwright.GleamPolicyCoreTest do
  use ExUnit.Case, async: true

  alias Wardwright.Policy.CoreRuntime

  test "structured core classifies successful guard-loop outcomes" do
    assert Wardwright.Policy.StructuredCore.success_status(0) == "completed"
    assert Wardwright.Policy.StructuredCore.success_status(2) == "completed_after_guard"

    assert Wardwright.Policy.StructuredCore.guard_rule_id_for_string(
             "semantic_validation",
             "structured-json",
             "minimum-confidence"
           ) == "minimum-confidence"
  end

  test "structured core classifies guard budget exhaustion before another retry" do
    assert Wardwright.Policy.StructuredCore.loop_outcome_status(
             "minimum-confidence",
             2,
             2,
             2,
             4
           ) == "exhausted_rule_budget"

    assert Wardwright.Policy.StructuredCore.loop_outcome_status(
             "structured-json",
             1,
             2,
             4,
             4
           ) == "exhausted_guard_budget"

    assert Wardwright.Policy.StructuredCore.loop_outcome_status(
             "structured-json",
             1,
             2,
             3,
             4
           ) == "continue"
  end

  test "history core classifies threshold decisions over the recent window" do
    decision =
      Wardwright.Policy.HistoryCore.count_decision([true, false, true, true],
        threshold: 2,
        recent_limit: 3,
        working_set_size: 4,
        scope: "session_id"
      )

    assert {:triggered, "session_id", 2, 2, 3, 4} = decision

    decision =
      Wardwright.Policy.HistoryCore.count_decision([true, true, true, true],
        threshold: 3,
        recent_limit: 2,
        working_set_size: 4,
        scope: "session_id"
      )

    assert {:not_triggered, "session_id", 2, 3, 2, 4} = decision

    assert Wardwright.Policy.HistoryCore.triggered_count?(3, 3)
    refute Wardwright.Policy.HistoryCore.triggered_count?(2, 3)
  end

  test "alert core classifies queue capacity, duplicate, and terminal states" do
    config = %{"capacity" => 1, "on_full" => "dead_letter"}
    alert = %{"idempotency_key" => "key-1", "rule_id" => "alert-rule", "session_id" => "s1"}

    assert %{
             key: "key-1",
             outcome: "queued",
             queue_depth: 1,
             queue_capacity: 1
           } = Wardwright.Policy.AlertCore.decide_enqueue(config, 0, false, alert)

    assert %{outcome: "duplicate_suppressed"} =
             Wardwright.Policy.AlertCore.decide_enqueue(config, 1, true, alert)

    assert %{outcome: "dead_lettered"} =
             Wardwright.Policy.AlertCore.decide_enqueue(config, 1, false, alert)

    refute Wardwright.Policy.AlertCore.terminal?(:enqueued)
    assert Wardwright.Policy.AlertCore.terminal?(:dead_lettered)
  end

  test "action core normalizes policy actions and conflicts" do
    action =
      Wardwright.Policy.Action.normalize(
        %{"rule_id" => "private-local-only", "action" => "restrict_routes"},
        rule: %{"kind" => "route_gate", "priority" => "25"}
      )

    assert %{
             "action_schema" => "wardwright.policy_action.v1",
             "rule_id" => "private-local-only",
             "kind" => "route_gate",
             "action" => "restrict_routes",
             "phase" => "request.routing",
             "effect_type" => "route_constraint",
             "priority" => 25,
             "conflict_key" => "route_constraints",
             "conflict_policy" => "ordered"
           } = action

    assert [
             %{
               "conflict_schema" => "wardwright.policy_conflict.v1",
               "key" => "route_constraints",
               "class" => "ordered",
               "action_count" => 2,
               "rule_ids" => ["local-only", "strong-model"],
               "required_resolution" => "preserve policy declaration order"
             }
           ] =
             Wardwright.Policy.Action.conflicts([
               Wardwright.Policy.Action.normalize(%{
                 "rule_id" => "local-only",
                 "kind" => "route_gate",
                 "action" => "restrict_routes"
               }),
               Wardwright.Policy.Action.normalize(%{
                 "rule_id" => "strong-model",
                 "kind" => "route_gate",
                 "action" => "switch_model"
               })
             ])
  end

  test "action result core keeps policy blocks distinct from successful annotations" do
    assert %{
             "result_schema" => "wardwright.policy_result.v1",
             "status" => "ok",
             "action" => "block",
             "actions" => [%{"rule_id" => "deny", "effect_type" => "terminal"}]
           } =
             Wardwright.Policy.Action.normalize_result(%{
               "engine" => "primitive",
               "status" => "ok",
               "actions" => [%{"rule_id" => "deny", "action" => "block"}]
             })

    assert %{
             "status" => "error",
             "action" => "block",
             "actions" => []
           } =
             Wardwright.Policy.Action.normalize_result(%{
               "engine" => "wasm",
               "status" => "error",
               "reason" => "engine unavailable"
             })
  end

  test "route core classifies route strategies and reasons" do
    config = %{
      "synthetic_model" => "unit-model",
      "version" => "unit-version",
      "targets" => [
        %{"model" => "small/model", "context_window" => 16},
        %{"model" => "medium/model", "context_window" => 64},
        %{"model" => "large/model", "context_window" => 256}
      ],
      "dispatchers" => [
        %{"id" => "fit-dispatcher", "models" => ["small/model", "medium/model", "large/model"]}
      ]
    }

    assert %{
             route_type: "dispatcher",
             route_id: "fit-dispatcher",
             selected_provider: "medium",
             selected_model: "medium/model",
             reason: "estimated prompt exceeded smaller configured context windows",
             skipped: [%{"target" => "small/model", "reason" => "context_window_too_small"}]
           } = Wardwright.RoutePlanner.select(config, 32)

    assert %{
             route_type: "policy_override_fallback",
             reason:
               "policy forced model was not in the allowed route set; explicit policy fallback allowed",
             selected_model: "medium/model",
             fallback_used: true
           } =
             Wardwright.RoutePlanner.select(config, 32, %{
               "forced_model" => "missing/model",
               "allow_fallback" => true
             })
  end

  test "Elixir and Gleam policy cores remain equivalent for representative decisions" do
    assert in_core(:compare, fn ->
             [
               Wardwright.Policy.StructuredCore.success_status(1),
               Wardwright.Policy.StructuredCore.loop_outcome_status(
                 "structured-json",
                 1,
                 3,
                 1,
                 2
               ),
               Wardwright.Policy.HistoryCore.count_decision([true, false, true],
                 threshold: 2,
                 recent_limit: 3,
                 working_set_size: 3,
                 scope: "session_id"
               ),
               Wardwright.Policy.AlertCore.decide_enqueue(
                 %{"capacity" => 1, "on_full" => "fail_closed"},
                 1,
                 false,
                 %{"idempotency_key" => "key-1", "rule_id" => "alert-rule"}
               ),
               Wardwright.Policy.Action.normalize(%{
                 "rule_id" => "block-private",
                 "kind" => "request_guard",
                 "action" => "block",
                 "message" => "private data blocked"
               }),
               Wardwright.Policy.Action.normalize_result(%{
                 "engine" => "primitive",
                 "status" => "ok",
                 "actions" => [
                   %{"rule_id" => "local-only", "action" => "restrict_routes"},
                   %{"rule_id" => "strong-model", "action" => "switch_model"}
                 ]
               }),
               Wardwright.RoutePlanner.select(
                 %{
                   "synthetic_model" => "unit-model",
                   "version" => "unit-version",
                   "targets" => [
                     %{"model" => "cheap/model", "context_window" => 128},
                     %{"model" => "strong/model", "context_window" => 128}
                   ],
                   "alloys" => [
                     %{
                       "id" => "blend",
                       "strategy" => "all",
                       "constituents" => ["cheap/model", "strong/model"]
                     }
                   ]
                 },
                 64
               )
             ]
           end) ==
             in_core(:elixir, fn ->
               [
                 Wardwright.Policy.StructuredCore.success_status(1),
                 Wardwright.Policy.StructuredCore.loop_outcome_status(
                   "structured-json",
                   1,
                   3,
                   1,
                   2
                 ),
                 Wardwright.Policy.HistoryCore.count_decision([true, false, true],
                   threshold: 2,
                   recent_limit: 3,
                   working_set_size: 3,
                   scope: "session_id"
                 ),
                 Wardwright.Policy.AlertCore.decide_enqueue(
                   %{"capacity" => 1, "on_full" => "fail_closed"},
                   1,
                   false,
                   %{"idempotency_key" => "key-1", "rule_id" => "alert-rule"}
                 ),
                 Wardwright.Policy.Action.normalize(%{
                   "rule_id" => "block-private",
                   "kind" => "request_guard",
                   "action" => "block",
                   "message" => "private data blocked"
                 }),
                 Wardwright.Policy.Action.normalize_result(%{
                   "engine" => "primitive",
                   "status" => "ok",
                   "actions" => [
                     %{"rule_id" => "local-only", "action" => "restrict_routes"},
                     %{"rule_id" => "strong-model", "action" => "switch_model"}
                   ]
                 }),
                 Wardwright.RoutePlanner.select(
                   %{
                     "synthetic_model" => "unit-model",
                     "version" => "unit-version",
                     "targets" => [
                       %{"model" => "cheap/model", "context_window" => 128},
                       %{"model" => "strong/model", "context_window" => 128}
                     ],
                     "alloys" => [
                       %{
                         "id" => "blend",
                         "strategy" => "all",
                         "constituents" => ["cheap/model", "strong/model"]
                       }
                     ]
                   },
                   64
                 )
               ]
             end)
  end

  defp in_core(core, fun), do: CoreRuntime.with_core(core, fun)
end
