defmodule ElixirIngaryTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  @opts ElixirIngary.Router.init([])

  setup do
    ElixirIngary.ReceiptStore.clear()
    :ok
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
