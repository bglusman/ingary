defmodule Wardwright.GleamPolicyCoreTest do
  use ExUnit.Case, async: true

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

  test "plan core classifies policy thresholds, sequence windows, and scope decisions" do
    assert Wardwright.Policy.PlanCore.threshold(0) == 1
    assert Wardwright.Policy.PlanCore.threshold_triggered?(2, 2)
    refute Wardwright.Policy.PlanCore.threshold_triggered?(1, 2)

    assert Wardwright.Policy.PlanCore.tool_policy_status("block") == "blocked"
    assert Wardwright.Policy.PlanCore.tool_policy_status("switch_model") == "rerouted"
    assert Wardwright.Policy.PlanCore.tool_policy_status("alert_async") == "alerted"
    assert Wardwright.Policy.PlanCore.tool_policy_status("annotate") == "allowed"

    assert Wardwright.Policy.PlanCore.scope_label("") == "session"
    assert Wardwright.Policy.PlanCore.scope_label("run_id") == "run"

    assert Wardwright.Policy.PlanCore.state_scope_matches?("", "reviewing")
    assert Wardwright.Policy.PlanCore.state_scope_matches?("reviewing", "reviewing")
    refute Wardwright.Policy.PlanCore.state_scope_matches?("reviewing", "active")

    assert Wardwright.Policy.PlanCore.sequence_window_limit(nil, nil) == 21
    assert Wardwright.Policy.PlanCore.sequence_window_limit(0, nil) == 2
    assert Wardwright.Policy.PlanCore.sequence_window_limit(nil, 4) == 5

    assert Wardwright.Policy.PlanCore.within_wall_clock_window?(100, 1_100, 1_001)
    refute Wardwright.Policy.PlanCore.within_wall_clock_window?(100, 1_102, 1_001)

    assert Wardwright.Policy.PlanCore.event_after?(10, 2, 10, 1)
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

  test "Gleam policy cores produce representative route and policy decisions" do
    assert Wardwright.Policy.StructuredCore.success_status(1) == "completed_after_guard"

    assert {:triggered, "session_id", 2, 2, 3, 3} =
             Wardwright.Policy.HistoryCore.count_decision([true, false, true],
               threshold: 2,
               recent_limit: 3,
               working_set_size: 3,
               scope: "session_id"
             )

    assert %{outcome: "failed_closed"} =
             Wardwright.Policy.AlertCore.decide_enqueue(
               %{"capacity" => 1, "on_full" => "fail_closed"},
               1,
               false,
               %{"idempotency_key" => "key-1", "rule_id" => "alert-rule"}
             )

    assert %{"action" => "block", "effect_type" => "terminal"} =
             Wardwright.Policy.Action.normalize(%{
               "rule_id" => "block-private",
               "kind" => "request_guard",
               "action" => "block",
               "message" => "private data blocked"
             })

    assert %{route_type: "dispatcher", selected_model: "medium/model"} =
             Wardwright.RoutePlanner.select(
               %{
                 "synthetic_model" => "unit-model",
                 "version" => "unit-version",
                 "targets" => [
                   %{"model" => "small/model", "context_window" => 16},
                   %{"model" => "medium/model", "context_window" => 64},
                   %{"model" => "large/model", "context_window" => 256}
                 ],
                 "route_root" => "fit-dispatcher",
                 "dispatchers" => [
                   %{
                     "id" => "fit-dispatcher",
                     "models" => ["small/model", "medium/model", "large/model"]
                   }
                 ]
               },
               32
             )
  end

  test "extended Gleam kernels produce public policy-surface decisions" do
    assert %{
             route_blocked: true,
             selected_model: "unconfigured/no-target",
             reason: "policy forced model was too small for estimated prompt"
           } = route_forced_model_context_block()

    assert [
             {:ok, "answer_v1", %{"answer" => "final"}},
             {:error, "semantic_validation", "answer-not-draft"},
             {:error, "schema_validation", "structured-json"}
           ] = structured_output_validation_results()

    assert [
             %{status: "completed", action: "rewrite_chunk", chunks: rewritten_chunks},
             %{status: "completed", action: "drop_chunk", chunks: dropped_chunks}
           ] = stream_window_results()

    assert Enum.join(rewritten_chunks) == "abc NewClient( done"
    assert Enum.join(dropped_chunks) == "keep  done"

    assert [context, true, false] = tool_context_results()
    assert context["phase"] == "result_interpretation"
    assert get_in(context, ["primary_tool", "namespace"]) == "openai.function"
    assert get_in(context, ["primary_tool", "name"]) == "create_ticket"

    assert [1, true, "rerouted", "session", false, 2, false, true] = plan_core_results()

    assert [
             ["observing", "guarding", "retrying", "recording"],
             [],
             %{"actions" => ["state_transition"]},
             %{"actions" => ["deny_tool"]},
             route_effects
           ] = projection_results()

    assert Enum.any?(route_effects, &(&1["target"] == "route"))
  end

  defp route_forced_model_context_block do
    Wardwright.RoutePlanner.select(
      %{
        "synthetic_model" => "unit-model",
        "version" => "unit-version",
        "targets" => [
          %{"model" => "small/model", "context_window" => 16},
          %{"model" => "medium/model", "context_window" => 128}
        ],
        "dispatchers" => [
          %{"id" => "fit-dispatcher", "models" => ["small/model", "medium/model"]}
        ]
      },
      64,
      %{"forced_model" => "small/model", "allow_fallback" => false}
    )
  end

  defp structured_output_validation_results do
    config = %{
      "schemas" => %{
        "answer_v1" => %{
          "type" => "object",
          "required" => ["answer", "confidence"],
          "properties" => %{
            "answer" => %{"type" => "string", "minLength" => 1},
            "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
            "citations" => %{"type" => "array", "items" => %{"type" => "string"}}
          },
          "additionalProperties" => false
        }
      },
      "semantic_rules" => [
        %{
          "id" => "minimum-confidence",
          "kind" => "json_path_number",
          "path" => "/confidence",
          "gte" => 0.7
        },
        %{
          "id" => "answer-not-draft",
          "kind" => "json_path_string_not_contains",
          "path" => "/answer",
          "pattern" => "draft"
        }
      ]
    }

    [
      Wardwright.Policy.StructuredOutput.validate_output(
        ~s({"answer":"final","confidence":0.91,"citations":["one"]}),
        config
      )
      |> strip_structured_payload(),
      Wardwright.Policy.StructuredOutput.validate_output(
        ~s({"answer":"draft","confidence":0.91}),
        config
      ),
      Wardwright.Policy.StructuredOutput.validate_output(
        ~s({"answer":"final","confidence":1.2}),
        config
      )
    ]
  end

  defp strip_structured_payload({:ok, schema_id, parsed}),
    do: {:ok, schema_id, Map.take(parsed, ["answer"])}

  defp strip_structured_payload(result), do: result

  defp stream_window_results do
    [
      Wardwright.Policy.Stream.evaluate(
        ["abc ", "OldClient(", " done"],
        [
          %{
            "id" => "bounded-rewrite",
            "contains" => "OldClient(",
            "action" => "rewrite_chunk",
            "replacement" => "NewClient(",
            "horizon_bytes" => byte_size("OldClient(")
          }
        ]
      )
      |> deterministic_stream_result(),
      Wardwright.Policy.Stream.evaluate(
        ["keep ", "DROP", " done"],
        [
          %{
            "id" => "bounded-drop",
            "contains" => "DROP",
            "action" => "drop_chunk",
            "horizon_bytes" => byte_size("DROP")
          }
        ]
      )
      |> deterministic_stream_result()
    ]
  end

  defp deterministic_stream_result(result) do
    Map.take(result, [
      :status,
      :action,
      :events,
      :chunks,
      :rewritten_bytes,
      :released_bytes,
      :held_bytes,
      :blocked_bytes,
      :trigger_count,
      :generated_bytes
    ])
  end

  defp tool_context_results do
    {_request, context} =
      Wardwright.ToolContext.normalize_request(%{
        "tools" => [
          %{
            "type" => "function",
            "function" => %{
              "name" => "create_ticket",
              "parameters" => %{"type" => "object"}
            }
          }
        ],
        "tool_choice" => %{
          "type" => "function",
          "function" => %{"name" => "create_ticket"}
        },
        "messages" => [
          %{"role" => "assistant", "tool_calls" => [%{"id" => "call_1"}]},
          %{"role" => "tool", "tool_call_id" => "call_1", "content" => "ok"}
        ]
      })

    [
      context,
      Wardwright.ToolContext.matches?(context, %{
        "namespaces" => ["openai.function"],
        "names" => ["create_ticket"],
        "phases" => ["result_interpretation"]
      }),
      Wardwright.ToolContext.matches?(context, %{"risk_classes" => ["write"]})
    ]
  end

  defp plan_core_results do
    [
      Wardwright.Policy.PlanCore.threshold(0),
      Wardwright.Policy.PlanCore.threshold_triggered?(3, 2),
      Wardwright.Policy.PlanCore.tool_policy_status("reroute"),
      Wardwright.Policy.PlanCore.scope_label("session_id"),
      Wardwright.Policy.PlanCore.state_scope_matches?("reviewing", "active"),
      Wardwright.Policy.PlanCore.sequence_window_limit(0, nil),
      Wardwright.Policy.PlanCore.within_wall_clock_window?(50, 120, 60),
      Wardwright.Policy.PlanCore.event_after?(120, 0, 100, 99)
    ]
  end

  defp projection_results do
    config = %{
      "synthetic_model" => "unit-model",
      "version" => "unit-version",
      "governance" => [
        %{"id" => "private-route", "kind" => "route_gate", "allowed_targets" => ["local/model"]},
        %{
          "id" => "transition-first",
          "kind" => "tool_sequence",
          "phase" => "tool.loop_governing",
          "transition_to" => "review_required",
          "then" => %{"action" => "annotate_receipt"}
        },
        %{"id" => "deny-shell", "kind" => "tool_denylist", "phase" => "tool.planning"}
      ],
      "stream_rules" => []
    }

    projection = Wardwright.PolicyProjection.projection("tool-governance", config)
    nodes = projection["phases"] |> Enum.flat_map(& &1["nodes"])
    transition_node = Enum.find(nodes, &(&1["id"] == "tool-policy.transition-first"))
    deny_node = Enum.find(nodes, &(&1["id"] == "tool-policy.deny-shell"))

    assert transition_node["writes"] == ["policy.actions", "policy_cache.session.policy_state"]
    assert deny_node["writes"] == ["decision.blocked", "tool.allowed"]

    [
      Wardwright.PolicyProjection.state_ids("tts-retry"),
      Wardwright.PolicyProjection.state_ids("unknown-pattern"),
      Map.take(transition_node, ["actions"]),
      Map.take(deny_node, ["actions"]),
      Wardwright.PolicyProjection.projection("route-privacy", config)["effects"]
    ]
  end
end
