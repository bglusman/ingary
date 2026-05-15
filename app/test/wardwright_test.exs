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

  test "lists flat and prefixed public models" do
    conn = call(:get, "/v1/models")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert Enum.map(body["data"], & &1["id"]) == ["coding-balanced", "wardwright/coding-balanced"]
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

    [receipt_id] = get_resp_header(conn, "x-wardwright-receipt-id")
    receipt = Wardwright.ReceiptStore.get(receipt_id)

    assert get_in(receipt, ["final", "stream_policy", "released_to_consumer"]) == false

    assert get_in(receipt, ["final", "stream_policy", "events", Access.at(0), "rule_id"]) ==
             "secret-stream"
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

  defp call(method, path, body \\ nil, headers \\ []) do
    encoded = if is_nil(body), do: nil, else: Jason.encode!(body)

    method
    |> conn(path, encoded)
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
