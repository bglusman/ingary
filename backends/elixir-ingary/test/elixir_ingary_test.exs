defmodule ElixirIngaryTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  import Plug.Conn
  import Plug.Test

  @opts ElixirIngary.Router.init([])

  setup do
    ElixirIngary.reset_config()
    ElixirIngary.ReceiptStore.clear()
    ElixirIngary.PolicyCache.reset()
    :ok
  end

  property "policy cache eviction keeps deterministic youngest entries" do
    check all(
            capacity <- integer(1..20),
            timestamps <- list_of(integer(0..50), max_length: 80)
          ) do
      ElixirIngary.PolicyCache.configure(%{"max_entries" => capacity, "recent_limit" => capacity})

      inserted =
        Enum.map(timestamps, fn timestamp ->
          {:ok, event} =
            ElixirIngary.PolicyCache.add(%{
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
        ElixirIngary.PolicyCache.recent(
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
        [{"x-ingary-session-id", "session-a"}]
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
        [{"x-ingary-session-id", "session-a"}]
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
    assert Enum.map(body["data"], & &1["id"]) == ["coding-balanced", "ingary/coding-balanced"]
  end

  test "chat completion records caller headers and selected model" do
    request = %{
      model: "ingary/coding-balanced",
      messages: [%{role: "user", content: "hello"}],
      metadata: %{consuming_agent_id: "body-agent"}
    }

    conn =
      :post
      |> call("/v1/chat/completions", request, [{"x-ingary-agent-id", "header-agent"}])

    assert conn.status == 200
    assert get_resp_header(conn, "x-ingary-selected-model") == ["local/qwen-coder"]
    [receipt_id] = get_resp_header(conn, "x-ingary-receipt-id")

    receipt = ElixirIngary.ReceiptStore.get(receipt_id)

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
        model: "ingary/unit-model",
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

  test "test config rejects invalid route graph shapes" do
    prefixed = unit_policy_config() |> Map.put("synthetic_model", "ingary/unit-model")
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
    assert ElixirIngary.ReceiptStore.health() == %{
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
    System.put_env("INGARY_ALLOW_TEST_CREDENTIALS", "1")
    on_exit(fn -> System.delete_env("INGARY_ALLOW_TEST_CREDENTIALS") end)

    {:ok, _config} =
      ElixirIngary.put_config(%{
        "synthetic_model" => "coding-balanced",
        "version" => "2026-05-13.mock",
        "targets" => [
          %{
            "model" => "openai/gpt-test",
            "context_window" => 128_000,
            "provider_kind" => "openai-compatible",
            "provider_base_url" => "https://example.com/v1",
            "credential_env" => "INGARY_TEST_PROVIDER_KEY"
          }
        ]
      })

    assert [provider] = ElixirIngary.providers()
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

    ElixirIngary.ReceiptStore.insert(older)
    ElixirIngary.ReceiptStore.insert(newer_low_id)
    ElixirIngary.ReceiptStore.insert(newer_high_id)

    assert Enum.map(ElixirIngary.ReceiptStore.list(%{}, 10), & &1["receipt_id"]) == [
             "rcpt_z",
             "rcpt_a",
             "rcpt_b"
           ]

    assert ElixirIngary.ReceiptStore.list(%{}, 1) == [
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

    ElixirIngary.ReceiptStore.insert(live)
    ElixirIngary.ReceiptStore.insert(simulated)

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

    assert Enum.map(ElixirIngary.ReceiptStore.list(filters, 10), & &1["receipt_id"]) == [
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
    |> ElixirIngary.Router.call(@opts)
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
