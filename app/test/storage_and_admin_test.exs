defmodule Wardwright.StorageAndAdminTest do
  use Wardwright.RouterCase

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
    assert get_in(provider, ["capabilities", "auth_scheme"]) == "bearer"
    assert get_in(provider, ["capabilities", "stream_format"]) == "openai_sse"
    assert "usage" in get_in(provider, ["capabilities", "terminal_metadata"])
    refute Map.has_key?(provider, "credential_env")
    refute Map.has_key?(provider, "credential")
  end

  test "provider capabilities describe stream contract differences by provider kind" do
    {:ok, _config} =
      Wardwright.put_config(%{
        "synthetic_model" => "coding-balanced",
        "version" => "2026-05-13.mock",
        "targets" => [
          %{"model" => "ollama/llama-test", "context_window" => 128_000},
          %{
            "model" => "openai/gpt-test",
            "context_window" => 128_000,
            "provider_kind" => "openai-compatible",
            "provider_base_url" => "https://example.com/v1"
          },
          %{"model" => "local/mock-test", "context_window" => 32_768}
        ]
      })

    providers = Map.new(Wardwright.providers(), &{&1["id"], &1})

    assert get_in(providers, ["ollama", "capabilities", "stream_format"]) == "ollama_ndjson"
    assert get_in(providers, ["openai", "capabilities", "stream_format"]) == "openai_sse"
    assert get_in(providers, ["local", "capabilities", "stream_format"]) == "synthetic_chunks"

    assert get_in(providers, ["openai", "capabilities", "schema"]) ==
             "wardwright.provider_capabilities.v1"

    assert get_in(providers, ["openai", "capabilities", "unsupported_stream_delta_fields"]) == [
             "role",
             "tool_calls",
             "logprobs"
           ]

    assert get_in(providers, ["openai", "capabilities", "unsupported_request_fields"]) == [
             "tools",
             "tool_choice",
             "message.tool_calls",
             "message.tool_call_id",
             "message.role:tool"
           ]

    assert get_in(providers, ["ollama", "capabilities", "unsupported_request_fields"]) ==
             get_in(providers, ["openai", "capabilities", "unsupported_request_fields"])

    assert get_in(providers, ["ollama", "capabilities", "cancellation", "confidence"]) ==
             "needs_live_provider_smoke"

    assert get_in(providers, ["local", "capabilities", "cancellation", "confidence"]) ==
             "deterministic_local"
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

  test "policy scenario store can persist reviewed scenarios to a file" do
    path =
      Path.join(System.tmp_dir!(), "wardwright-policy-scenarios-#{System.unique_integer()}.json")

    on_exit(fn ->
      Wardwright.PolicyScenarioStore.configure_storage(nil)
      File.rm(path)
      File.rm("#{path}.tmp")
    end)

    assert {:ok, _state} = Wardwright.PolicyScenarioStore.configure_storage(path)

    assert {:ok, _scenario} =
             Wardwright.PolicyScenarioStore.create("tts-retry", %{
               "scenario_id" => "durable-reviewed-trigger",
               "title" => "Durable reviewed trigger",
               "source" => "assistant",
               "pinned" => true,
               "input_summary" => "A persisted scenario survives store reload.",
               "expected_behavior" => "The retry guard remains linked to the guarding state.",
               "verdict" => "passed",
               "trace" => [
                 %{
                   "id" => "durable-1",
                   "node_id" => "tts.no-old-client",
                   "label" => "persisted match",
                   "severity" => "pass",
                   "state_id" => "guarding"
                 }
               ]
             })

    assert File.exists?(path)

    assert {:ok, _state} = Wardwright.PolicyScenarioStore.configure_storage(nil)
    assert Wardwright.PolicyScenarioStore.list("tts-retry") == []

    assert {:ok, _state} = Wardwright.PolicyScenarioStore.configure_storage(path)

    assert [%{id: "durable-reviewed-trigger", source: "assistant"}] =
             Wardwright.PolicyScenarioStore.list("tts-retry")

    assert Wardwright.PolicyScenarioStore.health()["capabilities"]["durable"] == true
    assert Wardwright.PolicyScenarioStore.health()["capabilities"]["regression_export"] == true
    assert Wardwright.PolicyScenarioStore.health()["capabilities"]["unpinned_retention"] == true
  end

  test "policy scenario retention persists pruning while preserving pinned records" do
    path =
      Path.join(System.tmp_dir!(), "wardwright-policy-retention-#{System.unique_integer()}.json")

    on_exit(fn ->
      Wardwright.PolicyScenarioStore.configure_storage(nil)
      File.rm(path)
      File.rm("#{path}.tmp")
    end)

    assert {:ok, _state} = Wardwright.PolicyScenarioStore.configure_storage(path)

    for {id, pinned, created_at} <- [
          {"retention-pinned", true, "2026-05-01T00:00:00Z"},
          {"retention-old-unpinned", false, "2026-05-02T00:00:00Z"},
          {"retention-new-unpinned", false, "2026-05-03T00:00:00Z"}
        ] do
      assert {:ok, _scenario} =
               Wardwright.PolicyScenarioStore.create("tts-retry", %{
                 "scenario_id" => id,
                 "title" => "Retention #{id}",
                 "source" => "assistant",
                 "pinned" => pinned,
                 "created_at" => created_at,
                 "input_summary" => "A retained scenario survives pruning.",
                 "expected_behavior" =>
                   "Pinned evidence remains while old unpinned records prune.",
                 "verdict" => "passed",
                 "trace" => [
                   %{
                     "id" => "#{id}-trace",
                     "node_id" => "tts.no-old-client",
                     "label" => "retention fixture",
                     "severity" => "pass",
                     "state_id" => "guarding"
                   }
                 ]
               })
    end

    assert {:ok,
            %{
              "pruned_count" => 1,
              "remaining_unpinned_count" => 1,
              "pruned_scenario_ids" => ["retention-old-unpinned"]
            }} = Wardwright.PolicyScenarioStore.enforce_retention("tts-retry", 1)

    assert {:ok, _state} = Wardwright.PolicyScenarioStore.configure_storage(nil)
    assert Wardwright.PolicyScenarioStore.list("tts-retry") == []

    assert {:ok, _state} = Wardwright.PolicyScenarioStore.configure_storage(path)

    assert Wardwright.PolicyScenarioStore.list("tts-retry")
           |> Enum.map(& &1.id)
           |> MapSet.new() ==
             MapSet.new(["retention-new-unpinned", "retention-pinned"])

    assert {:ok,
            %{"scenario_count" => 1, "scenarios" => [%{"scenario_id" => "retention-pinned"}]}} =
             Wardwright.PolicyScenarioStore.regression_export("tts-retry")
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

  test "receipt list exposes and filters normalized tool context dimensions" do
    github_receipt =
      "rcpt_github_tool"
      |> receipt_fixture(1_800_000_000, "agent-a")
      |> put_in(["decision", "tool_context"], %{
        "schema" => "wardwright.tool_context.v1",
        "phase" => "planning",
        "tool_call_id" => "call_1",
        "primary_tool" => %{
          "namespace" => "mcp.github",
          "name" => "create_pull_request",
          "risk_class" => "write",
          "source" => "caller_metadata"
        }
      })

    browser_receipt =
      "rcpt_browser_tool"
      |> receipt_fixture(1_800_000_001, "agent-b")
      |> put_in(["decision", "tool_context"], %{
        "schema" => "wardwright.tool_context.v1",
        "phase" => "planning",
        "primary_tool" => %{
          "namespace" => "browser",
          "name" => "read_page",
          "risk_class" => "read_only",
          "source" => "caller_metadata"
        }
      })

    Wardwright.ReceiptStore.insert(github_receipt)
    Wardwright.ReceiptStore.insert(browser_receipt)

    assert [
             %{
               "receipt_id" => "rcpt_github_tool",
               "tool_namespace" => "mcp.github",
               "tool_name" => "create_pull_request",
               "tool_phase" => "planning",
               "tool_risk_class" => "write",
               "tool_source" => "caller_metadata",
               "tool_call_id" => "call_1"
             }
           ] =
             Wardwright.ReceiptStore.list(
               %{
                 "tool_namespace" => "mcp.github",
                 "tool_name" => "create_pull_request",
                 "tool_phase" => "planning",
                 "tool_risk_class" => "write",
                 "tool_source" => "caller_metadata",
                 "tool_call_id" => "call_1"
               },
               10
             )
  end
end
