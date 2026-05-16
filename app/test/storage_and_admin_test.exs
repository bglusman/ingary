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
end
