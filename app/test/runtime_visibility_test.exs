defmodule Wardwright.RuntimeVisibilityTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Wardwright.Runtime
  alias Wardwright.Runtime.Events

  @opts Wardwright.Router.init([])

  setup do
    Wardwright.reset_config()
    Wardwright.ReceiptStore.clear()
    Wardwright.PolicyCache.reset()
    :ok
  end

  test "session runtime publishes ordered visibility events without mutating siblings" do
    model = "runtime-model-#{System.unique_integer([:positive])}"
    version = "v1"
    session_a = "session-a-#{System.unique_integer([:positive])}"
    session_b = "session-b-#{System.unique_integer([:positive])}"
    topic_a = Events.topic(:session, model, version, session_a)

    assert :ok = Events.subscribe(topic_a)

    assert {:ok, pid_a} = Runtime.ensure_session(model, version, session_a)
    assert {:ok, pid_b} = Runtime.ensure_session(model, version, session_b)

    assert_receive {:wardwright_runtime_event, ^topic_a,
                    %{"type" => "session.started", "sequence" => 1}}

    assert {:ok, %{"type" => "route.selected", "sequence" => 2}} =
             Runtime.record_session_event(model, version, session_a, "route.selected", %{
               "selected_model" => "mock/a"
             })

    assert_receive {:wardwright_runtime_event, ^topic_a,
                    %{"type" => "route.selected", "sequence" => 2, "selected_model" => "mock/a"}}

    ref = Process.monitor(pid_a)
    Process.exit(pid_a, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid_a, :killed}

    assert Process.alive?(pid_b)

    assert %{"event_count" => 1, "session_id" => ^session_b} =
             Wardwright.Runtime.SessionRuntime.status(pid_b)
  end

  test "chat requests publish session and receipt visibility and expose runtime status" do
    model_topic = Events.topic(:model, "coding-balanced", "2026-05-13.mock")
    receipt_topic = Events.topic(:receipts)
    assert :ok = Events.subscribe(model_topic)
    assert :ok = Events.subscribe(receipt_topic)

    conn =
      :post
      |> call(
        "/v1/chat/completions",
        %{model: "coding-balanced", messages: [%{role: "user", content: "hello"}]},
        [{"x-wardwright-session-id", "runtime-session"}]
      )

    assert conn.status == 200

    assert_receive {:wardwright_runtime_event, ^model_topic,
                    %{
                      "type" => "session.started",
                      "session_id" => "runtime-session",
                      "sequence" => 1
                    }}

    assert_receive {:wardwright_runtime_event, ^model_topic,
                    %{
                      "type" => "route.selected",
                      "session_id" => "runtime-session",
                      "sequence" => 2
                    }}

    assert_receive {:wardwright_runtime_event, ^receipt_topic,
                    %{
                      "type" => "receipt.stored",
                      "session_id" => "runtime-session",
                      "status" => "completed"
                    }}

    assert_receive {:wardwright_runtime_event, ^model_topic,
                    %{
                      "type" => "receipt.finalized",
                      "session_id" => "runtime-session",
                      "sequence" => 3
                    }}

    status =
      :get
      |> call("/admin/runtime")
      |> then(&Jason.decode!(&1.resp_body))

    assert Enum.any?(status["models"], &(&1["model_id"] == "coding-balanced"))

    assert Enum.any?(
             status["sessions"],
             &(&1["model_id"] == "coding-balanced" and &1["session_id"] == "runtime-session" and
                 &1["event_count"] == 3)
           )
  end

  test "chat requests with malformed metadata still read session visibility headers" do
    session_id = "runtime-session-#{System.unique_integer([:positive])}"
    model_topic = Events.topic(:model, "coding-balanced", "2026-05-13.mock")
    assert :ok = Events.subscribe(model_topic)

    conn =
      call(
        :post,
        "/v1/chat/completions",
        %{
          model: "coding-balanced",
          messages: [%{role: "user", content: "hello with malformed metadata"}],
          metadata: "not-a-map"
        },
        [{"x-wardwright-session-id", session_id}]
      )

    assert conn.status == 200

    assert_receive {:wardwright_runtime_event, ^model_topic,
                    %{
                      "type" => "session.started",
                      "session_id" => ^session_id,
                      "sequence" => 1
                    }}

    assert_receive {:wardwright_runtime_event, ^model_topic,
                    %{
                      "type" => "route.selected",
                      "session_id" => ^session_id,
                      "sequence" => 2
                    }}

    status =
      :get
      |> call("/admin/runtime")
      |> then(&Jason.decode!(&1.resp_body))

    assert Enum.any?(
             status["sessions"],
             &(&1["model_id"] == "coding-balanced" and &1["session_id"] == session_id and
                 &1["event_count"] == 3)
           )
  end

  test "model runtime crash restarts without stopping another model session" do
    model_a = "runtime-model-a-#{System.unique_integer([:positive])}"
    model_b = "runtime-model-b-#{System.unique_integer([:positive])}"
    version = "v1"

    assert {:ok, model_a_pid} = Runtime.ensure_model(model_a, version)
    assert {:ok, _model_b_pid} = Runtime.ensure_model(model_b, version)
    assert {:ok, session_b_pid} = Runtime.ensure_session(model_b, version, "session-b")

    ref = Process.monitor(model_a_pid)
    Process.exit(model_a_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^model_a_pid, :killed}

    assert Process.alive?(session_b_pid)

    restarted_model_a_pid =
      wait_for(fn ->
        case Runtime.ensure_model(model_a, version) do
          {:ok, pid} when pid != model_a_pid -> pid
          _ -> nil
        end
      end)

    assert Process.alive?(restarted_model_a_pid)
  end

  test "provider runtime exposes attempt health through admin runtime status" do
    models_topic = Events.topic(:models)

    assert :ok = Events.subscribe(models_topic)

    target = %{
      "model" => "direct/provider-health",
      "provider_kind" => "canned_sequence",
      "provider_timeout_ms" => 50
    }

    assert {:ok, "first response"} =
             Wardwright.ProviderRuntime.complete(target, %{}, fn -> {:ok, "first response"} end)

    assert {:error, "upstream exploded"} =
             Wardwright.ProviderRuntime.complete(target, %{}, fn ->
               {:error, "upstream exploded"}
             end)

    assert_receive {:wardwright_runtime_event, ^models_topic,
                    %{
                      "type" => "provider.attempt.finished",
                      "model" => "direct/provider-health",
                      "status" => "completed"
                    }}

    assert_receive {:wardwright_runtime_event, ^models_topic,
                    %{
                      "type" => "provider.attempt.finished",
                      "model" => "direct/provider-health",
                      "status" => "provider_error",
                      "created_at" => finished_at
                    }}

    status =
      :get
      |> call("/admin/runtime")
      |> then(&Jason.decode!(&1.resp_body))

    assert %{
             "provider_id" => "direct",
             "model" => "direct/provider-health",
             "configured" => false,
             "health" => "degraded",
             "attempt_count" => 2,
             "completed_count" => 1,
             "error_count" => 1,
             "consecutive_failures" => 1,
             "last_status" => "provider_error",
             "last_attempt_at" => ^finished_at
           } = Enum.find(status["providers"], &(&1["model"] == "direct/provider-health"))
  end

  defp wait_for(fun, attempts \\ 20)

  defp wait_for(fun, attempts) when attempts > 0 do
    case fun.() do
      nil ->
        Process.sleep(10)
        wait_for(fun, attempts - 1)

      value ->
        value
    end
  end

  defp wait_for(_fun, 0), do: flunk("condition was not met before timeout")

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
end
