defmodule WardwrightTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  import Plug.Conn
  import Plug.Test

  @opts Wardwright.Router.init([])

  setup do
    Wardwright.reset_config()
    Wardwright.ReceiptStore.clear()
    Wardwright.PolicyCache.reset()
    :ok
  end

  property "policy cache eviction keeps deterministic youngest entries" do
    check all(
            capacity <- integer(1..20),
            timestamps <- list_of(integer(0..50), max_length: 80)
          ) do
      Wardwright.PolicyCache.configure(%{"max_entries" => capacity, "recent_limit" => capacity})

      inserted =
        Enum.map(timestamps, fn timestamp ->
          {:ok, event} =
            Wardwright.PolicyCache.add(%{
              "kind" => "tool_call",
              "key" => "shell:ls",
              "scope" => %{"session_id" => "session-a"},
              "created_at_unix_ms" => timestamp
            })

          {event["sequence"], timestamp}
        end)

      expected =
        inserted
        |> Enum.sort_by(fn {sequence, timestamp} -> {timestamp, sequence} end)
        |> Enum.take(-capacity)
        |> Enum.map(fn {sequence, _timestamp} -> sequence end)
        |> MapSet.new()

      recent =
        Wardwright.PolicyCache.recent(
          %{
            "kind" => "tool_call",
            "key" => "shell:ls",
            "scope" => %{"session_id" => "session-a"}
          },
          capacity
        )

      assert length(recent) == MapSet.size(expected)
      assert Enum.all?(recent, &MapSet.member?(expected, &1["sequence"]))
    end
  end

  test "policy cache filters require matching kind and key together" do
    Wardwright.PolicyCache.configure(%{"max_entries" => 8, "recent_limit" => 8})

    for {kind, key} <- [
          {"tool_call", "shell:ls"},
          {"tool_call", "shell:rm"},
          {"response_text", "shell:ls"}
        ] do
      assert {:ok, _event} =
               Wardwright.PolicyCache.add(%{
                 "kind" => kind,
                 "key" => key,
                 "scope" => %{"session_id" => "session-a"}
               })
    end

    assert [%{"kind" => "tool_call", "key" => "shell:ls"}] =
             Wardwright.PolicyCache.recent(%{
               "kind" => "tool_call",
               "key" => "shell:ls",
               "scope" => %{"session_id" => "session-a"}
             })
  end

  test "history threshold policy reads only configured cache scope" do
    config =
      unit_policy_config()
      |> Map.put("policy_cache", %{"max_entries" => 8, "recent_limit" => 8})
      |> Map.put("governance", [
        %{
          "id" => "repeat-tool",
          "kind" => "history_threshold",
          "action" => "escalate",
          "cache_kind" => "tool_call",
          "cache_key" => "shell:ls",
          "cache_scope" => "session_id",
          "threshold" => 2,
          "severity" => "warning"
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    assert call(:post, "/v1/policy-cache/events", %{
             kind: "tool_call",
             key: "shell:ls",
             scope: %{session_id: "session-a"}
           }).status == 201

    assert call(:post, "/v1/policy-cache/events", %{
             kind: "tool_call",
             key: "shell:ls",
             scope: %{session_id: "session-b"}
           }).status == 201

    miss =
      call(
        :post,
        "/v1/synthetic/simulate",
        %{request: %{model: "unit-model", messages: [%{role: "user", content: "hello"}]}},
        [{"x-wardwright-session-id", "session-a"}]
      )

    assert miss.status == 200
    assert get_in(Jason.decode!(miss.resp_body), ["receipt", "final", "alert_count"]) == 0

    assert call(:post, "/v1/policy-cache/events", %{
             kind: "tool_call",
             key: "shell:ls",
             scope: %{session_id: "session-a"}
           }).status == 201

    hit =
      call(
        :post,
        "/v1/synthetic/simulate",
        %{request: %{model: "unit-model", messages: [%{role: "user", content: "hello"}]}},
        [{"x-wardwright-session-id", "session-a"}]
      )

    body = Jason.decode!(hit.resp_body)
    assert get_in(body, ["receipt", "final", "alert_count"]) == 1

    assert get_in(body, ["receipt", "decision", "policy_actions", Access.at(0), "history_count"]) ==
             2
  end

  test "history threshold uses safe defaults for blank operator-facing fields" do
    config =
      unit_policy_config()
      |> Map.put("policy_cache", %{"max_entries" => 8, "recent_limit" => 8})
      |> Map.put("governance", [
        %{
          "id" => "repeat-tool",
          "kind" => "history_threshold",
          "action" => "annotate",
          "cache_kind" => "tool_call",
          "cache_key" => "shell:ls",
          "cache_scope" => "session_id",
          "threshold" => 0,
          "message" => "",
          "severity" => ""
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    assert call(:post, "/v1/policy-cache/events", %{
             kind: "tool_call",
             key: "shell:ls",
             scope: %{session_id: "session-a"}
           }).status == 201

    conn =
      call(
        :post,
        "/v1/synthetic/simulate",
        %{request: %{model: "unit-model", messages: [%{role: "user", content: "hello"}]}},
        [{"x-wardwright-session-id", "session-a"}]
      )

    action =
      get_in(Jason.decode!(conn.resp_body), [
        "receipt",
        "decision",
        "policy_actions",
        Access.at(0)
      ])

    assert action["message"] == "policy cache threshold matched"
    assert action["severity"] == "info"
    assert action["threshold"] == 1
    assert action["history_count"] == 1
  end

  test "lists flat and prefixed public models" do
    conn = call(:get, "/v1/models")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert Enum.map(body["data"], & &1["id"]) == ["coding-balanced", "wardwright/coding-balanced"]
  end

  test "public synthetic model discovery omits policy internals" do
    config =
      unit_policy_config()
      |> Map.put("prompt_transforms", %{"preamble" => "private operator prompt"})
      |> Map.put("governance", [
        %{"id" => "internal-policy", "kind" => "request_guard", "contains" => "secret marker"}
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn = call(:get, "/v1/synthetic/models")
    assert conn.status == 200

    [model] = Jason.decode!(conn.resp_body)["data"]
    assert model["id"] == "unit-model"
    assert model["active_version"] == "unit-version"
    assert model["route_type"] == "dispatcher"

    refute Map.has_key?(model, "governance")
    refute Map.has_key?(model, "prompt_transforms")
    refute Map.has_key?(model, "route_graph")
    refute Map.has_key?(model, "structured_output")
  end

  test "admin synthetic model endpoint keeps full policy record behind protection" do
    config =
      unit_policy_config()
      |> Map.put("prompt_transforms", %{"preamble" => "private operator prompt"})

    assert call(:post, "/__test/config", config).status == 200

    rejected = call(:get, "/admin/synthetic-models", nil, [], {203, 0, 113, 10})
    assert rejected.status == 403

    local = call(:get, "/admin/synthetic-models")
    assert local.status == 200

    [model] = Jason.decode!(local.resp_body)["data"]
    assert model["prompt_transforms"] == %{"preamble" => "private operator prompt"}
    assert is_list(model["governance"])
    assert is_map(model["route_graph"])
  end

  test "chat completion records caller headers and selected model" do
    request = %{
      model: "wardwright/coding-balanced",
      messages: [%{role: "user", content: "hello"}],
      metadata: %{consuming_agent_id: "body-agent"}
    }

    conn =
      :post
      |> call("/v1/chat/completions", request, [{"x-wardwright-agent-id", "header-agent"}])

    assert conn.status == 200
    assert get_resp_header(conn, "x-wardwright-selected-model") == ["local/qwen-coder"]
    [receipt_id] = get_resp_header(conn, "x-wardwright-receipt-id")

    receipt = Wardwright.ReceiptStore.get(receipt_id)

    assert get_in(receipt, ["caller", "consuming_agent_id"]) == %{
             "value" => "header-agent",
             "source" => "header"
           }
  end

  test "simulation can select the managed model for large prompts" do
    request = %{
      request: %{
        model: "coding-balanced",
        messages: [%{role: "user", content: String.duplicate("x", 140_000)}]
      }
    }

    conn = call(:post, "/v1/synthetic/simulate", request)
    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)
    assert get_in(body, ["receipt", "decision", "selected_model"]) == "managed/kimi-k2.6"
  end

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
        messages: [%{role: "user", content: "hard proof"}]
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

  test "structured output guard retries canned provider outputs and records guard receipts" do
    config =
      structured_policy_config(
        [
          "{not json",
          ~s({"answer":"missing confidence"}),
          ~s({"answer":"valid and confident","confidence":0.91})
        ],
        3
      )

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/chat/completions", %{
        model: "unit-model",
        messages: [%{role: "user", content: "return structured json"}]
      })

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    structured = get_in(body, ["wardwright", "structured_output"])
    assert structured["final_status"] == "completed_after_guard"
    assert structured["selected_schema"] == "answer_v1"
    assert structured["attempt_count"] == 3

    assert Enum.map(structured["guard_events"], & &1["guard_type"]) == [
             "json_syntax",
             "schema_validation"
           ]

    assert get_in(body, ["choices", Access.at(0), "message", "content"]) ==
             ~s({"answer":"valid and confident","confidence":0.91})
  end

  test "structured output guard fails closed when per-rule budget is exhausted" do
    config =
      structured_policy_config([
        ~s({"answer":"too uncertain one","confidence":0.1}),
        ~s({"answer":"too uncertain two","confidence":0.2}),
        ~s({"answer":"would have succeeded too late","confidence":0.95})
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn =
      call(:post, "/v1/chat/completions", %{
        model: "unit-model",
        messages: [%{role: "user", content: "return structured json"}]
      })

    assert conn.status == 422
    body = Jason.decode!(conn.resp_body)

    structured = get_in(body, ["wardwright", "structured_output"])
    assert structured["final_status"] == "exhausted_rule_budget"
    assert structured["exhausted_rule_id"] == "minimum-confidence"

    assert Enum.map(structured["guard_events"], & &1["rule_id"]) == [
             "minimum-confidence",
             "minimum-confidence"
           ]
  end

  test "structured semantic rules reject matched JSON pointer strings" do
    config =
      structured_policy_config([~s({"answer":"draft answer","confidence":0.95})], 3)
      |> get_in(["structured_output"])
      |> update_in(["semantic_rules"], fn rules ->
        rules ++
          [
            %{
              "id" => "answer-not-draft",
              "kind" => "json_path_string_not_contains",
              "path" => "/answer",
              "pattern" => "draft"
            }
          ]
      end)

    assert {:error, "semantic_validation", "answer-not-draft"} =
             Wardwright.Policy.StructuredOutput.validate_output(
               ~s({"answer":"draft answer","confidence":0.95}),
               config
             )

    assert {:ok, "answer_v1", %{"answer" => "final answer", "confidence" => 0.95}} =
             Wardwright.Policy.StructuredOutput.validate_output(
               ~s({"answer":"final answer","confidence":0.95}),
               config
             )
  end

  test "structured schema and semantic validation fail closed for boundary violations" do
    config = structured_policy_config([~s({"answer":"unused","confidence":0.95})], 3)

    for invalid_output <- [
          ~s({"answer":"extra field","confidence":0.95,"debug":true}),
          ~s({"answer":"too high","confidence":1.01}),
          ~s({"answer":"","confidence":0.95}),
          ~s({"answer":"bad citation","confidence":0.95,"citations":[123]})
        ] do
      assert {:error, "schema_validation", "structured-json"} =
               Wardwright.Policy.StructuredOutput.validate_output(
                 invalid_output,
                 config["structured_output"]
               )
    end

    invalid_path_config =
      config
      |> get_in(["structured_output"])
      |> put_in(["semantic_rules"], [
        %{
          "id" => "confidence-pointer-required",
          "kind" => "json_path_number",
          "path" => "confidence",
          "gte" => 0.7
        }
      ])

    assert {:error, "semantic_validation", "confidence-pointer-required"} =
             Wardwright.Policy.StructuredOutput.validate_output(
               ~s({"answer":"valid","confidence":0.95}),
               invalid_path_config
             )
  end

  test "structured semantic rules traverse nested JSON pointer paths" do
    config =
      structured_policy_config([~s({"answer":"unused","confidence":0.95})], 3)
      |> get_in(["structured_output"])
      |> put_in(["schemas"], %{
        "nested_answer_v1" => %{
          "type" => "object",
          "required" => ["answer"],
          "properties" => %{},
          "additionalProperties" => true
        }
      })
      |> put_in(["semantic_rules"], [
        %{
          "id" => "nested-minimum-confidence",
          "kind" => "json_path_number",
          "path" => "/answer/confidence",
          "gte" => 0.7
        }
      ])

    assert {:error, "semantic_validation", "nested-minimum-confidence"} =
             Wardwright.Policy.StructuredOutput.validate_output(
               ~s({"answer":{"text":"too uncertain","confidence":0.2}}),
               config
             )

    assert {:ok, "nested_answer_v1", _parsed} =
             Wardwright.Policy.StructuredOutput.validate_output(
               ~s({"answer":{"text":"confident","confidence":0.91}}),
               config
             )
  end

  test "structured guard honors integer attempt budgets exactly" do
    config =
      structured_policy_config(["{not json"], 5)
      |> get_in(["structured_output"])
      |> put_in(["guard_loop", "max_attempts"], 2)

    provider = fn _attempt_index ->
      %{
        content: "{not json",
        status: "completed",
        latency_ms: 0,
        error: nil,
        called_provider: false,
        mock: true,
        structured_output: nil
      }
    end

    result = Wardwright.Policy.StructuredOutput.run(config, provider)
    assert result.status == "exhausted_guard_budget"
    assert get_in(result.structured_output, ["attempt_count"]) == 2
    assert length(get_in(result.structured_output, ["guard_events"])) == 2
  end

  test "history regex threshold uses automatically recorded request text inside session scope" do
    config =
      unit_policy_config()
      |> Map.put("policy_cache", %{"max_entries" => 8, "recent_limit" => 8})
      |> Map.put("governance", [
        %{
          "id" => "dangerous-shell-history",
          "kind" => "history_regex_threshold",
          "action" => "alert_async",
          "cache_kind" => "request_text",
          "cache_key" => "chat_completion",
          "cache_scope" => "session_id",
          "pattern" => "rm\\s+-rf",
          "threshold" => 1,
          "severity" => "critical"
        }
      ])

    assert call(:post, "/__test/config", config).status == 200

    miss =
      call(
        :post,
        "/v1/synthetic/simulate",
        %{request: %{model: "unit-model", messages: [%{role: "user", content: "hello"}]}},
        [{"x-wardwright-session-id", "session-a"}]
      )

    assert get_in(Jason.decode!(miss.resp_body), ["receipt", "final", "alert_count"]) == 0

    hit =
      call(
        :post,
        "/v1/synthetic/simulate",
        %{
          request: %{
            model: "unit-model",
            messages: [%{role: "user", content: "please run rm -rf /tmp/demo"}]
          }
        },
        [{"x-wardwright-session-id", "session-a"}]
      )

    receipt = Jason.decode!(hit.resp_body)["receipt"]
    assert get_in(receipt, ["final", "alert_count"]) == 1
    assert [%{"outcome" => "queued"}] = get_in(receipt, ["final", "alert_delivery"])

    isolated =
      call(
        :post,
        "/v1/synthetic/simulate",
        %{request: %{model: "unit-model", messages: [%{role: "user", content: "hello"}]}},
        [{"x-wardwright-session-id", "session-b"}]
      )

    assert get_in(Jason.decode!(isolated.resp_body), ["receipt", "final", "alert_count"]) == 0
  end

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

    [receipt_id] = get_resp_header(conn, "x-wardwright-receipt-id")
    receipt = Wardwright.ReceiptStore.get(receipt_id)

    assert get_in(receipt, ["final", "stream_policy", "released_to_consumer"]) == false

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

    assert [
             %{
               "rule_id" => "split-secret-stream",
               "action" => "block",
               "chunk_index" => 1,
               "match_scope" => "stream_window"
             }
           ] = get_in(body, ["wardwright", "stream_policy", "events"])
  end

  test "stream policy retry_with_reminder restarts generation before release" do
    config =
      unit_policy_config()
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

  test "stream policy retry budget exhaustion keeps violating bytes unreleased" do
    config =
      unit_policy_config()
      |> Map.put("stream_rules", [
        %{
          "id" => "deprecated-client-budget",
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
            ["still OldClient(", "arg) now"]
          ]
        },
        messages: [%{role: "user", content: "stream code"}]
      })

    assert conn.status == 409
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

    body = Jason.decode!(conn.resp_body)
    assert get_in(body, ["wardwright", "status"]) == "stream_policy_retry_required"
    assert get_in(body, ["wardwright", "stream_policy", "released_to_consumer"]) == false
    refute conn.resp_body =~ "data:"

    [receipt_id] = get_resp_header(conn, "x-wardwright-receipt-id")
    receipt = Wardwright.ReceiptStore.get(receipt_id)
    stream_policy = get_in(receipt, ["final", "stream_policy"])

    assert stream_policy["retry_count"] == 1
    assert stream_policy["max_retries"] == 1
    assert stream_policy["released_to_consumer"] == false
    assert stream_policy["held_bytes"] > 0
    assert stream_policy["generated_bytes"] > 0
    assert stream_policy["released_bytes"] == 0

    assert [
             %{
               "status" => "stream_policy_retry_required",
               "released_to_consumer" => false,
               "generated_bytes" => first_attempt_bytes
             },
             %{
               "status" => "stream_policy_retry_required",
               "released_to_consumer" => false,
               "generated_bytes" => second_attempt_bytes
             }
           ] = stream_policy["attempts"]

    assert first_attempt_bytes > 0
    assert second_attempt_bytes > 0
  end

  test "stream policy retry budgets are scoped to the triggered rule" do
    config =
      unit_policy_config()
      |> Map.put("stream_rules", [
        %{
          "id" => "deprecated-client-no-retry",
          "contains" => "OldClient(",
          "action" => "retry_with_reminder",
          "reminder" => "Use NewClient instead.",
          "max_retries" => 0
        },
        %{
          "id" => "unrelated-generous-retry",
          "contains" => "OtherClient(",
          "action" => "retry_with_reminder",
          "reminder" => "Use ThirdClient instead.",
          "max_retries" => 3
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

    assert conn.status == 409
    body = Jason.decode!(conn.resp_body)

    assert get_in(body, ["wardwright", "stream_policy", "max_retries"]) == 0
    assert get_in(body, ["wardwright", "stream_policy", "retry_count"]) == 0
    assert get_in(body, ["wardwright", "stream_policy", "released_to_consumer"]) == false

    [receipt_id] = get_resp_header(conn, "x-wardwright-receipt-id")
    receipt = Wardwright.ReceiptStore.get(receipt_id)

    assert [
             %{
               "status" => "stream_policy_retry_required",
               "action" => "retry_with_reminder",
               "released_to_consumer" => false
             }
           ] = get_in(receipt, ["final", "stream_policy", "attempts"])
  end

  test "policy engine adapters fail closed for unsupported WASM and Dune failures" do
    assert %{"engine" => "wasm", "action" => "block", "status" => "error"} =
             Wardwright.Policy.Engine.evaluate(%{"engine" => "wasm"}, %{})

    assert %{"engine" => "dune", "action" => "block", "status" => "error"} =
             Wardwright.Policy.Engine.evaluate(
               %{"engine" => "dune", "source" => "raise \"nope\""},
               %{}
             )
  end

  test "test config rejects invalid route graph shapes" do
    prefixed = unit_policy_config() |> Map.put("synthetic_model", "wardwright/unit-model")
    conn = call(:post, "/__test/config", prefixed)
    assert conn.status == 400

    assert Jason.decode!(conn.resp_body)["error"]["message"] ==
             "synthetic_model must be unprefixed"

    duplicate =
      unit_policy_config()
      |> Map.put("targets", [
        %{"model" => "tiny/model", "context_window" => 8},
        %{"model" => "tiny/model", "context_window" => 16}
      ])

    conn = call(:post, "/__test/config", duplicate)
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["message"] == "duplicate target tiny/model"

    unknown_ref =
      unit_policy_config()
      |> Map.put("route_root", "bad-dispatcher")
      |> Map.put("dispatchers", [
        %{"id" => "bad-dispatcher", "models" => ["tiny/model", "missing/model"]}
      ])

    conn = call(:post, "/__test/config", unknown_ref)
    assert conn.status == 400

    assert Jason.decode!(conn.resp_body)["error"]["message"] ==
             "dispatcher bad-dispatcher references unknown target missing/model"

    zero_weight =
      unit_policy_config()
      |> Map.put("route_root", "bad-alloy")
      |> Map.put("alloys", [
        %{
          "id" => "bad-alloy",
          "strategy" => "weighted",
          "constituents" => [
            %{"model" => "tiny/model", "weight" => 0},
            %{"model" => "medium/model", "weight" => 10}
          ]
        }
      ])

    conn = call(:post, "/__test/config", zero_weight)
    assert conn.status == 400

    assert Jason.decode!(conn.resp_body)["error"]["message"] ==
             "alloy bad-alloy target tiny/model weight must be positive"
  end

  test "test config endpoint is disabled unless explicitly allowed" do
    previous = Application.get_env(:wardwright, :allow_test_config, false)
    Application.put_env(:wardwright, :allow_test_config, false)
    on_exit(fn -> Application.put_env(:wardwright, :allow_test_config, previous) end)

    conn = call(:post, "/__test/config", unit_policy_config())
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "not_found"
  end

  test "dispatcher selects the smallest fitting model and preserves larger fallbacks" do
    {:ok, _config} =
      Wardwright.put_config(%{
        "synthetic_model" => "unit-model",
        "version" => "unit-version",
        "targets" => [
          %{"model" => "small/model", "context_window" => 16},
          %{"model" => "medium/model", "context_window" => 64},
          %{"model" => "large/model", "context_window" => 256}
        ],
        "route_root" => "fit-dispatcher",
        "dispatchers" => [
          %{"id" => "fit-dispatcher", "models" => ["small/model", "medium/model", "large/model"]}
        ]
      })

    assert %{
             route_type: "dispatcher",
             selected_model: "medium/model",
             selected_models: ["medium/model", "large/model"],
             fallback_models: ["large/model"],
             skipped: [%{"target" => "small/model", "reason" => "context_window_too_small"}]
           } = Wardwright.select_route(32)
  end

  test "cascade keeps declaration order while skipping oversized targets" do
    {:ok, _config} =
      Wardwright.put_config(%{
        "synthetic_model" => "unit-model",
        "version" => "unit-version",
        "targets" => [
          %{"model" => "fast/model", "context_window" => 16},
          %{"model" => "steady/model", "context_window" => 128},
          %{"model" => "reserve/model", "context_window" => 256}
        ],
        "route_root" => "local-then-reserve",
        "cascades" => [
          %{
            "id" => "local-then-reserve",
            "models" => ["fast/model", "steady/model", "reserve/model"]
          }
        ]
      })

    assert %{
             route_type: "cascade",
             selected_model: "steady/model",
             selected_models: ["steady/model", "reserve/model"],
             fallback_models: ["reserve/model"],
             skipped: [%{"target" => "fast/model"}]
           } = Wardwright.select_route(96)
  end

  test "partial alloys use overlapping constituents until smaller contexts stop fitting" do
    {:ok, _config} =
      Wardwright.put_config(%{
        "synthetic_model" => "unit-model",
        "version" => "unit-version",
        "targets" => [
          %{"model" => "local/qwen", "context_window" => 32},
          %{"model" => "managed/kimi", "context_window" => 256}
        ],
        "route_root" => "local-kimi-partial",
        "alloys" => [
          %{
            "id" => "local-kimi-partial",
            "strategy" => "deterministic_all",
            "partial_context" => true,
            "constituents" => ["local/qwen", "managed/kimi"]
          }
        ]
      })

    assert %{
             route_type: "alloy",
             combine_strategy: "deterministic_all",
             selected_model: "local/qwen",
             selected_models: ["local/qwen", "managed/kimi"],
             skipped: []
           } = Wardwright.select_route(16)

    assert %{
             route_type: "alloy",
             combine_strategy: "deterministic_all",
             selected_model: "managed/kimi",
             selected_models: ["managed/kimi"],
             skipped: [%{"target" => "local/qwen", "reason" => "context_window_too_small"}]
           } = Wardwright.select_route(96)
  end

  test "weighted alloys respect weights and expose the selected plan in receipts" do
    {:ok, _config} =
      Wardwright.put_config(%{
        "synthetic_model" => "unit-model",
        "version" => "unit-version",
        "targets" => [
          %{"model" => "cheap/model", "context_window" => 128},
          %{"model" => "strong/model", "context_window" => 128}
        ],
        "route_root" => "weighted-blend",
        "alloys" => [
          %{
            "id" => "weighted-blend",
            "strategy" => "weighted",
            "min_context_window" => 128,
            "constituents" => [
              %{"model" => "cheap/model", "weight" => 1},
              %{"model" => "strong/model", "weight" => 100}
            ]
          }
        ]
      })

    conn =
      call(:post, "/v1/synthetic/simulate", %{
        request: %{
          model: "unit-model",
          messages: [%{role: "user", content: "small prompt"}]
        }
      })

    assert conn.status == 200
    receipt = Jason.decode!(conn.resp_body)["receipt"]

    assert get_in(receipt, ["decision", "route_type"]) == "alloy"
    assert get_in(receipt, ["decision", "strategy"]) == "weighted"
    assert get_in(receipt, ["decision", "selected_model"]) == "strong/model"
    assert get_in(receipt, ["decision", "selected_models"]) == ["strong/model", "cheap/model"]
  end

  test "receipt store exposes storage health metadata" do
    assert Wardwright.ReceiptStore.health() == %{
             "kind" => "memory",
             "contract_version" => "storage-contract-v0",
             "migration_version" => 1,
             "read_health" => "ok",
             "write_health" => "ok",
             "capabilities" => %{
               "durable" => false,
               "transactional" => true,
               "concurrent_writers" => false,
               "json_queries" => true,
               "event_replay" => true,
               "time_range_indexes" => false,
               "retention_jobs" => false
             }
           }
  end

  test "provider metadata reports credential source without secret reference names" do
    System.put_env("WARDWRIGHT_ALLOW_TEST_CREDENTIALS", "1")
    on_exit(fn -> System.delete_env("WARDWRIGHT_ALLOW_TEST_CREDENTIALS") end)

    {:ok, _config} =
      Wardwright.put_config(%{
        "synthetic_model" => "coding-balanced",
        "version" => "2026-05-13.mock",
        "targets" => [
          %{
            "model" => "openai/gpt-test",
            "context_window" => 128_000,
            "provider_kind" => "openai-compatible",
            "provider_base_url" => "https://example.com/v1",
            "credential_env" => "WARDWRIGHT_TEST_PROVIDER_KEY"
          }
        ]
      })

    assert [provider] = Wardwright.providers()
    assert provider["credential_source"] == "env"
    refute Map.has_key?(provider, "credential_env")
    refute Map.has_key?(provider, "credential")
  end

  test "admin storage endpoint exposes receipt store health" do
    conn = call(:get, "/admin/storage")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert body["kind"] == "memory"
    assert body["contract_version"] == "storage-contract-v0"
    assert body["migration_version"] == 1
    assert body["read_health"] == "ok"
    assert body["write_health"] == "ok"
  end

  test "protected prototype endpoints reject non-local callers without an admin token" do
    remote_ip = {203, 0, 113, 10}

    for {method, path, body} <- [
          {:get, "/admin/storage", nil},
          {:get, "/v1/receipts", nil},
          {:post, "/v1/policy-cache/events", %{"kind" => "request_text"}}
        ] do
      conn = call(method, path, body, [], remote_ip)
      assert conn.status == 403
      assert %{"error" => %{"code" => "protected_endpoint"}} = Jason.decode!(conn.resp_body)
    end
  end

  test "protected prototype endpoints accept configured admin bearer token" do
    previous = Application.get_env(:wardwright, :admin_token)
    Application.put_env(:wardwright, :admin_token, "local-review-token")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:wardwright, :admin_token, previous),
        else: Application.delete_env(:wardwright, :admin_token)
    end)

    rejected = call(:get, "/admin/storage", nil, [], {203, 0, 113, 10})
    assert rejected.status == 403

    conn =
      call(
        :get,
        "/admin/storage",
        nil,
        [{"authorization", "Bearer local-review-token"}],
        {203, 0, 113, 10}
      )

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["kind"] == "memory"
  end

  test "receipt list is deterministic and returns storage summaries" do
    older = receipt_fixture("rcpt_b", 1_800_000_000, "agent-b")
    newer_low_id = receipt_fixture("rcpt_a", 1_800_000_001, "agent-a")
    newer_high_id = receipt_fixture("rcpt_z", 1_800_000_001, "agent-z")

    Wardwright.ReceiptStore.insert(older)
    Wardwright.ReceiptStore.insert(newer_low_id)
    Wardwright.ReceiptStore.insert(newer_high_id)

    assert Enum.map(Wardwright.ReceiptStore.list(%{}, 10), & &1["receipt_id"]) == [
             "rcpt_z",
             "rcpt_a",
             "rcpt_b"
           ]

    assert Wardwright.ReceiptStore.list(%{}, 1) == [
             %{
               "receipt_id" => "rcpt_z",
               "created_at" => 1_800_000_001,
               "receipt_schema" => "v1",
               "synthetic_model" => "coding-balanced",
               "synthetic_version" => "2026-05-13.mock",
               "caller" => %{
                 "tenant_id" => %{"value" => "tenant-a", "source" => "header"},
                 "application_id" => %{"value" => "app-a", "source" => "header"},
                 "consuming_agent_id" => %{"value" => "agent-z", "source" => "header"},
                 "consuming_user_id" => %{"value" => "user-a", "source" => "header"},
                 "session_id" => %{"value" => "session-a", "source" => "header"},
                 "run_id" => %{"value" => "run-a", "source" => "header"}
               },
               "tenant_id" => "tenant-a",
               "application_id" => "app-a",
               "consuming_agent_id" => "agent-z",
               "consuming_user_id" => "user-a",
               "session_id" => "session-a",
               "run_id" => "run-a",
               "selected_provider" => "managed",
               "selected_model" => "managed/kimi-k2.6",
               "status" => "completed",
               "simulation" => false,
               "stream_policy_action" => nil
             }
           ]
  end

  test "receipt list supports storage contract filters" do
    live = receipt_fixture("rcpt_live", 1_800_000_000, "agent-a")
    simulated = receipt_fixture("rcpt_sim", 1_800_000_001, "agent-b", status: "simulated")

    Wardwright.ReceiptStore.insert(live)
    Wardwright.ReceiptStore.insert(simulated)

    filters = %{
      "tenant_id" => "tenant-a",
      "application_id" => "app-a",
      "consuming_agent_id" => "agent-b",
      "synthetic_model" => "coding-balanced",
      "synthetic_version" => "2026-05-13.mock",
      "selected_provider" => "managed",
      "selected_model" => "managed/kimi-k2.6",
      "status" => "simulated",
      "simulation" => "true",
      "created_at_min" => "1800000001",
      "created_at_max" => "1800000001"
    }

    assert Enum.map(Wardwright.ReceiptStore.list(filters, 10), & &1["receipt_id"]) == [
             "rcpt_sim"
           ]
  end

  defp call(method, path, body \\ nil, headers \\ [], remote_ip \\ {127, 0, 0, 1}) do
    encoded = if is_nil(body), do: nil, else: Jason.encode!(body)

    method
    |> conn(path, encoded)
    |> Map.put(:remote_ip, remote_ip)
    |> put_req_header("content-type", "application/json")
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {key, value}, acc -> put_req_header(acc, key, value) end)
    end)
    |> Wardwright.Router.call(@opts)
  end

  defp unit_policy_config do
    %{
      "synthetic_model" => "unit-model",
      "version" => "unit-version",
      "targets" => [
        %{"model" => "tiny/model", "context_window" => 8},
        %{"model" => "medium/model", "context_window" => 32},
        %{"model" => "large/model", "context_window" => 256}
      ],
      "governance" => [
        %{
          "id" => "ambiguous-success",
          "kind" => "request_guard",
          "action" => "escalate",
          "contains" => "looks done",
          "message" => "completion claim needs artifact",
          "severity" => "warning"
        }
      ]
    }
  end

  defp structured_policy_config(outputs, max_failures_per_rule \\ 2) do
    unit_policy_config()
    |> Map.put("targets", [
      %{
        "model" => "canned/model",
        "context_window" => 256,
        "provider_kind" => "canned_sequence",
        "canned_outputs" => outputs
      }
    ])
    |> Map.put("structured_output", %{
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
        }
      ],
      "guard_loop" => %{
        "max_attempts" => 4,
        "max_failures_per_rule" => max_failures_per_rule,
        "on_violation" => "retry_with_validation_feedback",
        "on_exhausted" => "block"
      }
    })
  end

  defp receipt_fixture(receipt_id, created_at, agent_id, opts \\ []) do
    status = Keyword.get(opts, :status, "completed")

    %{
      "receipt_schema" => "v1",
      "receipt_id" => receipt_id,
      "created_at" => created_at,
      "synthetic_model" => "coding-balanced",
      "synthetic_version" => "2026-05-13.mock",
      "simulation" => status == "simulated",
      "caller" => %{
        "tenant_id" => %{"value" => "tenant-a", "source" => "header"},
        "application_id" => %{"value" => "app-a", "source" => "header"},
        "consuming_agent_id" => %{"value" => agent_id, "source" => "header"},
        "consuming_user_id" => %{"value" => "user-a", "source" => "header"},
        "session_id" => %{"value" => "session-a", "source" => "header"},
        "run_id" => %{"value" => "run-a", "source" => "header"}
      },
      "decision" => %{
        "selected_provider" => "managed",
        "selected_model" => "managed/kimi-k2.6"
      },
      "final" => %{"status" => status},
      "events" => [
        %{"event_id" => receipt_id <> ":1", "receipt_id" => receipt_id, "sequence" => 1}
      ]
    }
  end
end
