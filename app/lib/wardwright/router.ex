defmodule Wardwright.Router do
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
    synthetic_model = Wardwright.synthetic_model_record()["id"]

    json(conn, 200, %{
      "object" => "list",
      "data" => [
        %{"id" => synthetic_model, "object" => "model", "owned_by" => "wardwright"},
        %{
          "id" => "wardwright/#{synthetic_model}",
          "object" => "model",
          "owned_by" => "wardwright"
        }
      ]
    })
  end

  get "/v1/synthetic/models" do
    json(conn, 200, %{"data" => [Wardwright.synthetic_model_record()]})
  end

  post "/v1/chat/completions" do
    with {:ok, request} <- require_json_object(conn.body_params),
         {:ok, model} <- Wardwright.normalize_model(Map.get(request, "model")),
         :ok <- require_messages(request) do
      request = apply_prompt_transforms(request)
      caller = caller_context(conn, Map.get(request, "metadata", %{}))
      {request, policy} = apply_request_policies(request, caller)
      decision = route_decision(request)

      record_runtime_event(model, caller, "route.selected", %{
        "selected_model" => decision.selected_model,
        "selected_provider" => decision.selected_provider,
        "estimated_prompt_tokens" => decision.estimated_prompt_tokens
      })

      provider =
        if Map.get(request, "stream") == true do
          %{
            content: nil,
            status: "completed",
            latency_ms: 0,
            error: nil,
            called_provider: false,
            mock: true
          }
        else
          Wardwright.complete_selected_model(decision.selected_model, request)
        end

      receipt =
        provider.status
        |> build_receipt(model, caller, request, decision, provider.called_provider, policy)
        |> apply_provider_outcome(provider)

      Wardwright.ReceiptStore.insert(receipt)

      record_runtime_event(model, caller, "receipt.finalized", %{
        "receipt_id" => receipt["receipt_id"],
        "status" => get_in(receipt, ["final", "status"]),
        "simulation" => false,
        "alert_count" => get_in(receipt, ["final", "alert_count"]) || 0
      })

      conn =
        conn
        |> put_resp_header("x-wardwright-receipt-id", receipt["receipt_id"])
        |> put_resp_header("x-wardwright-selected-model", decision.selected_model)

      if Map.get(request, "stream") == true do
        stream_chat(conn, request, decision)
      else
        json(conn, 200, chat_response(request, receipt, decision, provider.content))
      end
    else
      {:error, message} -> error(conn, 400, message, "invalid_request", "bad_request")
    end
  end

  post "/v1/synthetic/simulate" do
    with {:ok, body} <- require_json_object(conn.body_params),
         {:ok, request} <- require_json_object(Map.get(body, "request")),
         request = override_model(request, Map.get(body, "model")),
         {:ok, model} <- Wardwright.normalize_model(Map.get(request, "model")),
         :ok <- require_messages(request) do
      request = apply_prompt_transforms(request)
      caller = caller_context(conn, Map.get(request, "metadata", %{}))
      {request, policy} = apply_request_policies(request, caller)
      decision = route_decision(request)

      record_runtime_event(model, caller, "simulation.route_selected", %{
        "selected_model" => decision.selected_model,
        "selected_provider" => decision.selected_provider,
        "estimated_prompt_tokens" => decision.estimated_prompt_tokens
      })

      receipt = build_receipt("simulated", model, caller, request, decision, false, policy)
      Wardwright.ReceiptStore.insert(receipt)

      record_runtime_event(model, caller, "receipt.finalized", %{
        "receipt_id" => receipt["receipt_id"],
        "status" => get_in(receipt, ["final", "status"]),
        "simulation" => true,
        "alert_count" => get_in(receipt, ["final", "alert_count"]) || 0
      })

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
    receipts = Wardwright.ReceiptStore.list(filters, limit)
    json(conn, 200, %{"data" => receipts})
  end

  get "/v1/receipts/:receipt_id" do
    case Wardwright.ReceiptStore.get(receipt_id) do
      nil -> error(conn, 404, "receipt not found", "not_found", "receipt_not_found")
      receipt -> json(conn, 200, receipt)
    end
  end

  get "/admin/storage" do
    json(conn, 200, Wardwright.ReceiptStore.health())
  end

  get "/admin/runtime" do
    json(conn, 200, Wardwright.Runtime.status())
  end

  post "/v1/policy-cache/events" do
    with {:ok, event} <- Wardwright.PolicyCache.add(conn.body_params) do
      json(conn, 201, %{"event" => event})
    else
      {:error, message} ->
        error(conn, 400, message, "invalid_request", "invalid_policy_cache_event")
    end
  end

  get "/v1/policy-cache/recent" do
    filter = %{
      "kind" => blank_to_nil(Map.get(conn.query_params, "kind")),
      "key" => blank_to_nil(Map.get(conn.query_params, "key")),
      "scope" => cache_scope_from_query(conn.query_params)
    }

    limit = parse_limit(Map.get(conn.query_params, "limit"))
    json(conn, 200, %{"data" => Wardwright.PolicyCache.recent(filter, limit)})
  end

  get "/admin/providers" do
    json(conn, 200, %{"data" => Wardwright.providers()})
  end

  get "/admin/synthetic-models" do
    json(conn, 200, %{"data" => [Wardwright.synthetic_model_record()]})
  end

  post "/__test/config" do
    with {:ok, config} <- require_json_object(conn.body_params),
         {:ok, config} <- Wardwright.put_config(config) do
      Wardwright.ReceiptStore.clear()

      json(conn, 200, %{
        "status" => "ok",
        "synthetic_model" => config["synthetic_model"],
        "targets" => config["targets"]
      })
    else
      {:error, message} -> error(conn, 400, message, "invalid_request", "invalid_test_config")
    end
  end

  match _ do
    error(conn, 404, "not found", "not_found", "not_found")
  end

  defp require_json_object(value) when is_map(value), do: {:ok, value}
  defp require_json_object(_), do: {:error, "request body must be a JSON object"}

  defp override_model(request, nil), do: request
  defp override_model(request, ""), do: request
  defp override_model(request, model), do: Map.put(request, "model", model)

  defp apply_prompt_transforms(request) do
    transforms = Wardwright.current_config()["prompt_transforms"] || %{}
    messages = Map.get(request, "messages", [])

    messages =
      case transforms["preamble"] |> metadata_string() |> blank_to_nil() do
        nil ->
          messages

        text ->
          [%{"role" => "system", "name" => "wardwright_preamble", "content" => text} | messages]
      end

    messages =
      case transforms["postscript"] |> metadata_string() |> blank_to_nil() do
        nil ->
          messages

        text ->
          messages ++
            [%{"role" => "system", "name" => "wardwright_postscript", "content" => text}]
      end

    Map.put(request, "messages", messages)
  end

  defp apply_request_policies(request, caller) do
    text = request |> Map.get("messages", []) |> request_text() |> String.downcase()

    Enum.reduce(
      Wardwright.current_config()["governance"] || [],
      {request, empty_policy()},
      fn rule, {request, policy} ->
        kind = Map.get(rule, "kind", "")

        cond do
          kind == "history_threshold" ->
            apply_history_threshold_rule(rule, caller, request, policy)

          kind in ["request_guard", "request_transform", "receipt_annotation"] &&
              policy_match?(text, Map.get(rule, "contains")) ->
            action = Map.get(rule, "action", "annotate")
            rule_id = Map.get(rule, "id", "policy")

            message =
              rule |> Map.get("message", "request policy matched") |> blank_to_nil() ||
                "request policy matched"

            severity = rule |> Map.get("severity", "info") |> blank_to_nil() || "info"

            action_record = %{
              "rule_id" => rule_id,
              "kind" => kind,
              "action" => action,
              "matched" => true,
              "message" => message,
              "severity" => severity
            }

            case action do
              "escalate" ->
                event = %{
                  "type" => "policy.alert",
                  "rule_id" => rule_id,
                  "message" => message,
                  "severity" => severity
                }

                {request,
                 policy
                 |> Map.update!("actions", &[action_record | &1])
                 |> Map.update!("events", &[event | &1])
                 |> Map.update!("alert_count", &(&1 + 1))}

              action when action in ["inject_reminder_and_retry", "transform"] ->
                reminder = rule |> Map.get("reminder", message) |> blank_to_nil() || message

                message_record = %{
                  "role" => "system",
                  "name" => "wardwright_policy_reminder",
                  "content" => reminder
                }

                request =
                  Map.update(request, "messages", [message_record], fn messages ->
                    messages ++ [message_record]
                  end)

                action_record = Map.put(action_record, "reminder_injected", true)
                {request, Map.update!(policy, "actions", &[action_record | &1])}

              "annotate" ->
                event = %{
                  "type" => "policy.annotated",
                  "rule_id" => rule_id,
                  "message" => message,
                  "severity" => severity
                }

                {request,
                 policy
                 |> Map.update!("actions", &[action_record | &1])
                 |> Map.update!("events", &[event | &1])}

              _ ->
                {request, Map.update!(policy, "actions", &[action_record | &1])}
            end

          true ->
            {request, policy}
        end
      end
    )
    |> then(fn {request, policy} ->
      policy =
        policy
        |> Map.update!("actions", &Enum.reverse/1)
        |> Map.update!("events", &Enum.reverse/1)

      {request, policy}
    end)
  end

  defp empty_policy, do: %{"actions" => [], "events" => [], "alert_count" => 0}

  defp apply_history_threshold_rule(rule, caller, request, policy) do
    threshold = max(1, integer_value(Map.get(rule, "threshold", 1)) || 1)

    filter = %{
      "kind" => blank_to_nil(Map.get(rule, "cache_kind")),
      "key" => blank_to_nil(Map.get(rule, "cache_key")),
      "scope" => cache_scope_from_caller(caller, Map.get(rule, "cache_scope", ""))
    }

    count = Wardwright.PolicyCache.count(filter)

    if count < threshold do
      {request, policy}
    else
      action = Map.get(rule, "action", "annotate")
      rule_id = Map.get(rule, "id", "policy")

      message =
        rule |> Map.get("message", "policy cache threshold matched") |> blank_to_nil() ||
          "policy cache threshold matched"

      severity = rule |> Map.get("severity", "info") |> blank_to_nil() || "info"

      action_record = %{
        "rule_id" => rule_id,
        "kind" => "history_threshold",
        "action" => action,
        "matched" => true,
        "message" => message,
        "severity" => severity,
        "cache_kind" => Map.get(rule, "cache_kind", ""),
        "cache_key" => Map.get(rule, "cache_key", ""),
        "cache_scope" => Map.get(rule, "cache_scope", ""),
        "history_count" => count,
        "threshold" => threshold
      }

      policy = Map.update!(policy, "actions", &[action_record | &1])

      if action == "escalate" do
        event = %{
          "type" => "policy.alert",
          "rule_id" => rule_id,
          "message" => message,
          "severity" => severity,
          "history_count" => count,
          "threshold" => threshold
        }

        {request,
         policy
         |> Map.update!("events", &[event | &1])
         |> Map.update!("alert_count", &(&1 + 1))}
      else
        {request, policy}
      end
    end
  end

  defp policy_match?(_text, value) when value in [nil, ""], do: false

  defp policy_match?(text, value) do
    String.contains?(text, value |> metadata_string() |> String.downcase())
  end

  defp request_text(messages) when is_list(messages) do
    Enum.map_join(messages, "\n", fn message ->
      "#{Map.get(message, "role", "")}\n#{metadata_string(Map.get(message, "content"))}"
    end)
  end

  defp request_text(_), do: ""

  defp require_messages(%{"messages" => messages}) when is_list(messages) and messages != [],
    do: :ok

  defp require_messages(_), do: {:error, "messages must not be empty"}

  defp route_decision(request) do
    estimate = Wardwright.estimate_prompt_tokens(Map.get(request, "messages", []))
    Wardwright.select_route(estimate)
  end

  defp caller_context(conn, metadata) when is_map(metadata) do
    %{}
    |> put_sourced(
      "tenant_id",
      header_or_metadata(conn, metadata, "x-wardwright-tenant-id", "tenant_id")
    )
    |> put_sourced(
      "application_id",
      header_or_metadata(conn, metadata, "x-wardwright-application-id", "application_id")
    )
    |> put_sourced(
      "consuming_agent_id",
      header_or_metadata(conn, metadata, "x-wardwright-agent-id", "consuming_agent_id") ||
        header_or_metadata(conn, metadata, "x-wardwright-agent-id", "agent_id")
    )
    |> put_sourced(
      "consuming_user_id",
      header_or_metadata(conn, metadata, "x-wardwright-user-id", "consuming_user_id") ||
        header_or_metadata(conn, metadata, "x-wardwright-user-id", "user_id")
    )
    |> put_sourced(
      "session_id",
      header_or_metadata(conn, metadata, "x-wardwright-session-id", "session_id")
    )
    |> put_sourced("run_id", header_or_metadata(conn, metadata, "x-wardwright-run-id", "run_id"))
    |> put_sourced(
      "client_request_id",
      header_or_metadata(conn, metadata, "x-client-request-id", "client_request_id")
    )
    |> Map.put("tags", metadata_tags(metadata))
  end

  defp caller_context(conn, _metadata), do: caller_context(conn, %{})

  defp session_id(caller), do: get_in(caller, ["session_id", "value"])

  defp record_runtime_event(model, caller, type, fields) do
    version = Wardwright.current_config()["version"]

    case Wardwright.Runtime.record_session_event(
           model,
           version,
           session_id(caller),
           type,
           fields
         ) do
      {:ok, _event} -> :ok
      _ -> :ok
    end
  end

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

  defp cache_scope_from_query(params) do
    [
      "tenant_id",
      "application_id",
      "consuming_agent_id",
      "consuming_user_id",
      "session_id",
      "run_id"
    ]
    |> Enum.reduce(%{}, fn key, acc ->
      case blank_to_nil(Map.get(params, key)) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp cache_scope_from_caller(_caller, scope_name) when scope_name in [nil, ""], do: %{}

  defp cache_scope_from_caller(caller, scope_name) do
    scope_name = metadata_string(scope_name)

    case get_in(caller, [scope_name, "value"]) do
      nil -> %{}
      "" -> %{}
      value -> %{scope_name => value}
    end
  end

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp integer_value(_), do: nil

  defp build_receipt(status, model, caller, request, decision, called_provider, policy) do
    receipt_id = "rcpt_" <> random_hex(8)
    created_at = System.system_time(:second)

    %{
      "receipt_schema" => "v1",
      "receipt_id" => receipt_id,
      "created_at" => created_at,
      "run_id" => get_in(caller, ["run_id", "value"]),
      "synthetic_model" => model,
      "synthetic_version" => Wardwright.current_config()["version"],
      "simulation" => status == "simulated",
      "caller" => caller,
      "request" => %{
        "model" => Map.get(request, "model"),
        "normalized_model" => model,
        "estimated_prompt_tokens" => decision.estimated_prompt_tokens,
        "stream" => Map.get(request, "stream", false),
        "message_count" => length(Map.get(request, "messages", [])),
        "prompt_transforms" => Wardwright.current_config()["prompt_transforms"],
        "structured_output" => Wardwright.current_config()["structured_output"]
      },
      "decision" => %{
        "strategy" => "estimated_prompt_length",
        "selected_provider" => decision.selected_provider,
        "selected_model" => decision.selected_model,
        "estimated_prompt_tokens" => decision.estimated_prompt_tokens,
        "skipped" => decision.skipped,
        "reason" => decision.reason,
        "rule" => "select the smallest configured context window that fits the estimated prompt",
        "governance" => Wardwright.current_config()["governance"],
        "policy_actions" => policy["actions"]
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
        "alert_count" => policy["alert_count"],
        "events" => policy["events"],
        "receipt_recorded_at" =>
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      },
      "events" => receipt_events(receipt_id, created_at, status, decision, called_provider)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp apply_provider_outcome(receipt, provider) do
    receipt
    |> update_in(["attempts", Access.at(0)], fn attempt ->
      attempt
      |> Map.put("status", provider.status)
      |> Map.put("mock", provider.mock)
      |> Map.put("called_provider", provider.called_provider)
      |> Map.put("latency_ms", provider.latency_ms)
      |> put_if_present("provider_error", provider.error)
    end)
    |> update_in(["final"], fn final ->
      final
      |> Map.put("status", provider.status)
      |> put_if_present("provider_error", provider.error)
    end)
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp chat_response(request, receipt, decision, provider_content) do
    completion_tokens = 18

    content =
      provider_content ||
        "Mock Wardwright response routed to #{decision.selected_model}. Estimated prompt tokens: #{decision.estimated_prompt_tokens}."

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
            "content" => content
          },
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{
        "prompt_tokens" => decision.estimated_prompt_tokens,
        "completion_tokens" => completion_tokens,
        "total_tokens" => decision.estimated_prompt_tokens + completion_tokens
      },
      "wardwright" => %{
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
      "Mock Wardwright stream ",
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
      "Content-Type, X-Wardwright-Tenant-Id, X-Wardwright-Application-Id, X-Wardwright-Agent-Id, X-Wardwright-User-Id, X-Wardwright-Session-Id, X-Wardwright-Run-Id, X-Client-Request-Id"
    )
    |> put_resp_header(
      "access-control-expose-headers",
      "X-Wardwright-Receipt-Id, X-Wardwright-Selected-Model"
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
