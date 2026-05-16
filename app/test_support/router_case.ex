defmodule Wardwright.Test.StreamingProvider do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  post "/ollama/api/chat" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    chunks =
      cond do
        body =~ "Use NewClient instead." ->
          ["use NewClient(", "arg) now"]

        body =~ "safe prefix" ->
          ["safe prefix that can release ", "Old", "Client(arg) now"]

        true ->
          ["use Old", "Client(arg) now"]
      end

    conn =
      conn
      |> Plug.Conn.put_resp_content_type("application/x-ndjson")
      |> Plug.Conn.send_chunked(200)

    conn =
      Enum.reduce(chunks, conn, fn chunk, conn ->
        {:ok, conn} =
          Plug.Conn.chunk(
            conn,
            Jason.encode!(%{"message" => %{"content" => chunk}, "done" => false}) <> "\n"
          )

        conn
      end)

    {:ok, conn} =
      Plug.Conn.chunk(
        conn,
        Jason.encode!(%{
          "done" => true,
          "done_reason" => "stop",
          "total_duration" => 123,
          "prompt_eval_count" => 4,
          "eval_count" => 2
        }) <> "\n"
      )

    conn
  end

  post "/openai/chat/completions" do
    {:ok, _body, conn} = Plug.Conn.read_body(conn)

    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer test-openai-key"] ->
        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        {:ok, conn} =
          Plug.Conn.chunk(
            conn,
            "data: " <>
              Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "hello "}}]}) <>
              "\n\n"
          )

        {:ok, conn} =
          Plug.Conn.chunk(
            conn,
            "event: completion.delta\n" <>
              "data:" <>
              Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "world"}}]}) <>
              "\n\n"
          )

        {:ok, conn} =
          Plug.Conn.chunk(
            conn,
            "data: " <>
              Jason.encode!(%{
                "choices" => [%{"delta" => %{}, "finish_reason" => "stop", "index" => 0}],
                "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5}
              }) <>
              "\n\n"
          )

        {:ok, conn} = Plug.Conn.chunk(conn, "data: [DONE]\n\n")
        conn

      _ ->
        Plug.Conn.send_resp(conn, 401, "missing authorization")
    end
  end

  match _ do
    Plug.Conn.send_resp(conn, 404, "not found")
  end
end

defmodule Wardwright.RouterCase do
  @moduledoc false

  use ExUnit.CaseTemplate
  import Plug.Conn
  import Plug.Test

  using do
    quote do
      use ExUnit.Case, async: false
      import Plug.Conn
      import Plug.Test
      import Wardwright.RouterCase
    end
  end

  setup do
    Wardwright.reset_config()
    Wardwright.ReceiptStore.clear()
    Wardwright.PolicyScenarioStore.clear()
    Wardwright.PolicyCache.reset()
    :ok
  end

  @opts Wardwright.Router.init([])

  def call(method, path, body \\ nil, headers \\ [], remote_ip \\ {127, 0, 0, 1}) do
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

  def streaming_provider_base_url(prefix) do
    ref = :"wardwright_streaming_provider_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Plug.Cowboy.http(Wardwright.Test.StreamingProvider, [], ref: ref, port: 0)
    port = :ranch.get_port(ref)
    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    "http://127.0.0.1:#{port}#{prefix}"
  end

  def unit_policy_config do
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

  def structured_policy_config(outputs, max_failures_per_rule \\ 2) do
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

  def receipt_fixture(receipt_id, created_at, agent_id, opts \\ []) do
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
