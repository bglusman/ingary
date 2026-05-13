defmodule ElixirIngary.Router do
  @moduledoc false

  use Plug.Router

  plug(Plug.Logger)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: 1_048_576
  )

  plug(:cors)
  plug(:match)
  plug(:dispatch)

  options _ do
    send_resp(conn, 204, "")
  end

  get "/v1/models" do
    json(conn, 200, %{
      "object" => "list",
      "data" => [
        %{"id" => ElixirIngary.synthetic_model(), "object" => "model", "owned_by" => "ingary"},
        %{
          "id" => "ingary/#{ElixirIngary.synthetic_model()}",
          "object" => "model",
          "owned_by" => "ingary"
        }
      ]
    })
  end

  get "/v1/synthetic/models" do
    json(conn, 200, %{"data" => [ElixirIngary.synthetic_model_record()]})
  end

  post "/v1/chat/completions" do
    with {:ok, request} <- require_json_object(conn.body_params),
         {:ok, model} <- ElixirIngary.normalize_model(Map.get(request, "model")),
         :ok <- require_messages(request) do
      caller = caller_context(conn, Map.get(request, "metadata", %{}))
      decision = route_decision(request)
      receipt = build_receipt("completed", model, caller, request, decision, true)
      ElixirIngary.ReceiptStore.insert(receipt)

      conn =
        conn
        |> put_resp_header("x-ingary-receipt-id", receipt["receipt_id"])
        |> put_resp_header("x-ingary-selected-model", decision.selected_model)

      if Map.get(request, "stream") == true do
        stream_chat(conn, request, decision)
      else
        json(conn, 200, chat_response(request, receipt, decision))
      end
    else
      {:error, message} -> error(conn, 400, message, "invalid_request", "bad_request")
    end
  end

  post "/v1/synthetic/simulate" do
    with {:ok, body} <- require_json_object(conn.body_params),
         {:ok, request} <- require_json_object(Map.get(body, "request")),
         request = override_model(request, Map.get(body, "model")),
         {:ok, model} <- ElixirIngary.normalize_model(Map.get(request, "model")),
         :ok <- require_messages(request) do
      caller = caller_context(conn, Map.get(request, "metadata", %{}))
      decision = route_decision(request)
      receipt = build_receipt("simulated", model, caller, request, decision, false)
      ElixirIngary.ReceiptStore.insert(receipt)
      json(conn, 200, %{"receipt" => receipt})
    else
      {:error, message} -> error(conn, 400, message, "invalid_request", "bad_request")
    end
  end

  get "/v1/receipts" do
    filters =
      conn.query_params
      |> Map.take([
        "model",
        "consuming_agent_id",
        "consuming_user_id",
        "session_id",
        "run_id",
        "status",
        "tenant_id",
        "application_id",
        "synthetic_model",
        "synthetic_version",
        "selected_provider",
        "selected_model",
        "simulation",
        "stream_policy_action",
        "created_at_min",
        "created_at_max"
      ])
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    limit = parse_limit(Map.get(conn.query_params, "limit"))
    receipts = ElixirIngary.ReceiptStore.list(filters, limit)
    json(conn, 200, %{"data" => receipts})
  end

  get "/v1/receipts/:receipt_id" do
    case ElixirIngary.ReceiptStore.get(receipt_id) do
      nil -> error(conn, 404, "receipt not found", "not_found", "receipt_not_found")
      receipt -> json(conn, 200, receipt)
    end
  end

  get "/admin/storage" do
    json(conn, 200, ElixirIngary.ReceiptStore.health())
  end

  get "/admin/providers" do
    json(conn, 200, %{"data" => ElixirIngary.providers()})
  end

  get "/admin/synthetic-models" do
    json(conn, 200, %{"data" => [ElixirIngary.synthetic_model_record()]})
  end

  match _ do
    error(conn, 404, "not found", "not_found", "not_found")
  end

  defp require_json_object(value) when is_map(value), do: {:ok, value}
  defp require_json_object(_), do: {:error, "request body must be a JSON object"}

  defp override_model(request, nil), do: request
  defp override_model(request, ""), do: request
  defp override_model(request, model), do: Map.put(request, "model", model)

  defp require_messages(%{"messages" => messages}) when is_list(messages) and messages != [],
    do: :ok

  defp require_messages(_), do: {:error, "messages must not be empty"}

  defp route_decision(request) do
    estimate = ElixirIngary.estimate_prompt_tokens(Map.get(request, "messages", []))
    selected_model = ElixirIngary.select_provider_model(estimate)
    selected_provider = selected_model |> String.split("/", parts: 2) |> List.first()

    reason =
      if selected_model == ElixirIngary.local_model() do
        "estimated prompt fits local context window"
      else
        "estimated prompt exceeds local context window"
      end

    %{
      estimated_prompt_tokens: estimate,
      selected_model: selected_model,
      selected_provider: selected_provider,
      reason: reason
    }
  end

  defp caller_context(conn, metadata) when is_map(metadata) do
    %{}
    |> put_sourced(
      "tenant_id",
      header_or_metadata(conn, metadata, "x-ingary-tenant-id", "tenant_id")
    )
    |> put_sourced(
      "application_id",
      header_or_metadata(conn, metadata, "x-ingary-application-id", "application_id")
    )
    |> put_sourced(
      "consuming_agent_id",
      header_or_metadata(conn, metadata, "x-ingary-agent-id", "consuming_agent_id") ||
        header_or_metadata(conn, metadata, "x-ingary-agent-id", "agent_id")
    )
    |> put_sourced(
      "consuming_user_id",
      header_or_metadata(conn, metadata, "x-ingary-user-id", "consuming_user_id") ||
        header_or_metadata(conn, metadata, "x-ingary-user-id", "user_id")
    )
    |> put_sourced(
      "session_id",
      header_or_metadata(conn, metadata, "x-ingary-session-id", "session_id")
    )
    |> put_sourced("run_id", header_or_metadata(conn, metadata, "x-ingary-run-id", "run_id"))
    |> put_sourced(
      "client_request_id",
      header_or_metadata(conn, metadata, "x-client-request-id", "client_request_id")
    )
    |> Map.put("tags", metadata_tags(metadata))
  end

  defp caller_context(conn, _metadata), do: caller_context(conn, %{})

  defp header_or_metadata(conn, metadata, header_name, metadata_key) do
    case conn |> get_req_header(header_name) |> List.first() |> blank_to_nil() do
      nil ->
        metadata
        |> Map.get(metadata_key)
        |> metadata_string()
        |> blank_to_nil()
        |> case do
          nil -> nil
          value -> %{"value" => value, "source" => "body_metadata"}
        end

      value ->
        %{"value" => value, "source" => "header"}
    end
  end

  defp put_sourced(map, _key, nil), do: map
  defp put_sourced(map, key, value), do: Map.put(map, key, value)

  defp metadata_tags(%{"tags" => tags}) when is_list(tags) do
    tags
    |> Enum.map(&metadata_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.sort()
  end

  defp metadata_tags(%{"tags" => tags}) when is_binary(tags) do
    tags
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.sort()
  end

  defp metadata_tags(_), do: []

  defp metadata_string(value) when is_binary(value), do: String.trim(value)
  defp metadata_string(value) when is_integer(value), do: Integer.to_string(value)
  defp metadata_string(value) when is_float(value), do: Float.to_string(value)
  defp metadata_string(value) when is_boolean(value), do: to_string(value)
  defp metadata_string(_), do: ""

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp build_receipt(status, model, caller, request, decision, called_provider) do
    receipt_id = "rcpt_" <> random_hex(8)
    created_at = System.system_time(:second)

    %{
      "receipt_schema" => "v1",
      "receipt_id" => receipt_id,
      "created_at" => created_at,
      "run_id" => get_in(caller, ["run_id", "value"]),
      "synthetic_model" => model,
      "synthetic_version" => ElixirIngary.synthetic_version(),
      "simulation" => status == "simulated",
      "caller" => caller,
      "request" => %{
        "model" => Map.get(request, "model"),
        "normalized_model" => model,
        "estimated_prompt_tokens" => decision.estimated_prompt_tokens,
        "stream" => Map.get(request, "stream", false),
        "message_count" => length(Map.get(request, "messages", []))
      },
      "decision" => %{
        "strategy" => "estimated_prompt_length",
        "selected_provider" => decision.selected_provider,
        "selected_model" => decision.selected_model,
        "estimated_prompt_tokens" => decision.estimated_prompt_tokens,
        "reason" => decision.reason,
        "threshold_tokens" => ElixirIngary.local_context_window()
      },
      "attempts" => [
        %{
          "provider_id" => decision.selected_model |> String.split("/") |> List.first(),
          "model" => decision.selected_model,
          "status" => status,
          "mock" => true,
          "called_provider" => called_provider
        }
      ],
      "final" => %{
        "status" => status,
        "selected_model" => decision.selected_model,
        "stream_trigger_count" => 0,
        "receipt_recorded_at" =>
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      },
      "events" => receipt_events(receipt_id, created_at, status, decision, called_provider)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp chat_response(request, receipt, decision) do
    completion_tokens = 18

    %{
      "id" => "chatcmpl_" <> receipt["receipt_id"],
      "object" => "chat.completion",
      "created" => System.system_time(:second),
      "model" => Map.get(request, "model"),
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" =>
              "Mock Ingary response routed to #{decision.selected_model}. Estimated prompt tokens: #{decision.estimated_prompt_tokens}."
          },
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{
        "prompt_tokens" => decision.estimated_prompt_tokens,
        "completion_tokens" => completion_tokens,
        "total_tokens" => decision.estimated_prompt_tokens + completion_tokens
      },
      "ingary" => %{
        "receipt_id" => receipt["receipt_id"],
        "selected_model" => decision.selected_model
      }
    }
  end

  defp stream_chat(conn, request, decision) do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    chunks = [
      "Mock Ingary stream ",
      "routed to #{decision.selected_model} ",
      "for #{Map.get(request, "model")} with #{decision.estimated_prompt_tokens} estimated prompt tokens."
    ]

    conn =
      Enum.reduce(Enum.with_index(chunks), conn, fn {text, index}, acc ->
        payload = %{
          "id" => "chatcmpl_stream_mock",
          "object" => "chat.completion.chunk",
          "created" => System.system_time(:second),
          "model" => Map.get(request, "model"),
          "choices" => [%{"index" => index, "delta" => %{"content" => text}}]
        }

        {:ok, acc} = chunk(acc, "data: #{Jason.encode!(payload)}\n\n")
        acc
      end)

    {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
    conn
  end

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end

  defp cors(conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, POST, OPTIONS")
    |> put_resp_header(
      "access-control-allow-headers",
      "Content-Type, X-Ingary-Tenant-Id, X-Ingary-Application-Id, X-Ingary-Agent-Id, X-Ingary-User-Id, X-Ingary-Session-Id, X-Ingary-Run-Id, X-Client-Request-Id"
    )
    |> put_resp_header(
      "access-control-expose-headers",
      "X-Ingary-Receipt-Id, X-Ingary-Selected-Model"
    )
  end

  defp error(conn, status, message, type, code) do
    json(conn, status, %{
      "error" => %{
        "message" => message,
        "type" => type,
        "code" => code
      }
    })
  end

  defp parse_limit(nil), do: 50

  defp parse_limit(raw) do
    case Integer.parse(raw) do
      {value, ""} -> value |> max(1) |> min(500)
      _ -> 50
    end
  end

  defp receipt_events(receipt_id, created_at, status, decision, called_provider) do
    [
      %{
        "event_id" => receipt_id <> ":1",
        "receipt_id" => receipt_id,
        "sequence" => 1,
        "type" => "route.selected",
        "created_at" => created_at,
        "selected_provider" => decision.selected_provider,
        "selected_model" => decision.selected_model
      },
      %{
        "event_id" => receipt_id <> ":2",
        "receipt_id" => receipt_id,
        "sequence" => 2,
        "type" => "provider.attempted",
        "created_at" => created_at,
        "called_provider" => called_provider
      },
      %{
        "event_id" => receipt_id <> ":3",
        "receipt_id" => receipt_id,
        "sequence" => 3,
        "type" => "receipt.finalized",
        "created_at" => created_at,
        "status" => status
      }
    ]
  end

  defp random_hex(bytes) do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
