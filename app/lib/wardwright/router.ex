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
    json(conn, 200, %{"data" => [Wardwright.synthetic_model_summary()]})
  end

  post "/v1/chat/completions" do
    with {:ok, request} <- require_json_object(conn.body_params),
         {:ok, model} <- Wardwright.normalize_model(Map.get(request, "model")),
         :ok <- require_messages(request) do
      request = apply_prompt_transforms(request)
      caller = caller_context(conn, Map.get(request, "metadata", %{}))
      Wardwright.Policy.History.record_request(caller, request)
      {request, policy} = apply_request_policies(request, caller)
      {policy, fail_closed?} = deliver_policy_alerts(policy)
      decision = route_decision(request, policy)

      record_runtime_event(model, caller, "route.selected", %{
        "selected_model" => decision.selected_model,
        "selected_provider" => decision.selected_provider,
        "estimated_prompt_tokens" => decision.estimated_prompt_tokens
      })

      provider = provider_outcome(request, decision, fail_closed?)
      Wardwright.Policy.History.record_response(caller, provider.content)

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

      status = response_status(receipt)

      if Map.get(request, "stream") == true and status == 200 do
        stream_chat(conn, request, decision, Map.get(provider, :stream_chunks))
      else
        json(
          conn,
          status,
          chat_response(request, receipt, decision, provider.content)
        )
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
      Wardwright.Policy.History.record_request(caller, request)
      {request, policy} = apply_request_policies(request, caller)
      {policy, fail_closed?} = deliver_policy_alerts(policy)
      decision = route_decision(request, policy)

      record_runtime_event(model, caller, "simulation.route_selected", %{
        "selected_model" => decision.selected_model,
        "selected_provider" => decision.selected_provider,
        "estimated_prompt_tokens" => decision.estimated_prompt_tokens
      })

      status =
        if fail_closed? or decision.route_blocked, do: "policy_failed_closed", else: "simulated"

      receipt = build_receipt(status, model, caller, request, decision, false, policy)
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
    with :ok <- require_protected_access(conn) do
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
    else
      {:error, :protected, message} ->
        error(conn, 403, message, "forbidden", "protected_endpoint")
    end
  end

  get "/v1/receipts/:receipt_id" do
    with :ok <- require_protected_access(conn) do
      case Wardwright.ReceiptStore.get(receipt_id) do
        nil -> error(conn, 404, "receipt not found", "not_found", "receipt_not_found")
        receipt -> json(conn, 200, receipt)
      end
    else
      {:error, :protected, message} ->
        error(conn, 403, message, "forbidden", "protected_endpoint")
    end
  end

  get "/admin/storage" do
    with :ok <- require_protected_access(conn) do
      json(conn, 200, Wardwright.ReceiptStore.health())
    else
      {:error, :protected, message} ->
        error(conn, 403, message, "forbidden", "protected_endpoint")
    end
  end

  get "/admin/runtime" do
    with :ok <- require_protected_access(conn) do
      json(conn, 200, Wardwright.Runtime.status())
    else
      {:error, :protected, message} ->
        error(conn, 403, message, "forbidden", "protected_endpoint")
    end
  end

  get "/admin/policy-alerts" do
    with :ok <- require_protected_access(conn) do
      json(conn, 200, Wardwright.Policy.AlertDelivery.status())
    else
      {:error, :protected, message} ->
        error(conn, 403, message, "forbidden", "protected_endpoint")
    end
  end

  post "/v1/policy-cache/events" do
    with :ok <- require_protected_access(conn),
         {:ok, event} <- Wardwright.PolicyCache.add(conn.body_params) do
      json(conn, 201, %{"event" => event})
    else
      {:error, :protected, message} ->
        error(conn, 403, message, "forbidden", "protected_endpoint")

      {:error, message} ->
        error(conn, 400, message, "invalid_request", "invalid_policy_cache_event")
    end
  end

  get "/v1/policy-cache/recent" do
    with :ok <- require_protected_access(conn) do
      filter = %{
        "kind" => blank_to_nil(Map.get(conn.query_params, "kind")),
        "key" => blank_to_nil(Map.get(conn.query_params, "key")),
        "scope" => cache_scope_from_query(conn.query_params)
      }

      limit = parse_limit(Map.get(conn.query_params, "limit"))
      json(conn, 200, %{"data" => Wardwright.PolicyCache.recent(filter, limit)})
    else
      {:error, :protected, message} ->
        error(conn, 403, message, "forbidden", "protected_endpoint")
    end
  end

  get "/admin/providers" do
    with :ok <- require_protected_access(conn) do
      json(conn, 200, %{"data" => Wardwright.providers()})
    else
      {:error, :protected, message} ->
        error(conn, 403, message, "forbidden", "protected_endpoint")
    end
  end

  get "/admin/synthetic-models" do
    with :ok <- require_protected_access(conn) do
      json(conn, 200, %{"data" => [Wardwright.synthetic_model_record()]})
    else
      {:error, :protected, message} ->
        error(conn, 403, message, "forbidden", "protected_endpoint")
    end
  end

  post "/__test/config" do
    if test_config_allowed?() do
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
    else
      error(conn, 404, "not found", "not_found", "not_found")
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

  defp apply_request_policies(request, caller),
    do: Wardwright.Policy.Plan.evaluate_request(request, caller)

  defp deliver_policy_alerts(%{"events" => events} = policy) do
    alert_delivery = Wardwright.Policy.AlertDelivery.deliver(events)

    policy =
      policy
      |> Map.put("alert_delivery", alert_delivery)
      |> Map.put(
        "failed_closed",
        Map.get(policy, "blocked", false) or
          Wardwright.Policy.AlertDelivery.fail_closed?(alert_delivery)
      )

    {policy, policy["failed_closed"]}
  end

  defp provider_outcome(_request, _decision, true) do
    %{
      content: nil,
      status: "policy_failed_closed",
      latency_ms: 0,
      error: "policy failed closed",
      called_provider: false,
      mock: true,
      structured_output: nil
    }
  end

  defp provider_outcome(_request, %{route_blocked: true}, false) do
    %{
      content: nil,
      status: "policy_failed_closed",
      latency_ms: 0,
      error: "route policy removed all provider targets",
      called_provider: false,
      mock: true,
      structured_output: nil
    }
  end

  defp provider_outcome(request, decision, false) when is_map(request) do
    if Map.get(request, "stream") == true do
      stream_policy = evaluate_stream_policy(request, decision)

      %{
        content: nil,
        status: stream_policy.status,
        latency_ms: Map.get(stream_policy, :provider_latency_ms, 0),
        error: Map.get(stream_policy, :provider_error),
        called_provider: Map.get(stream_policy, :called_provider, false),
        mock: Map.get(stream_policy, :mock, true),
        structured_output: nil,
        stream_chunks: stream_policy.chunks,
        stream_policy: stream_policy
      }
    else
      structured_config = Wardwright.current_config()["structured_output"]

      Wardwright.Policy.StructuredOutput.run(structured_config, fn attempt_index ->
        request
        |> Map.put("wardwright_attempt_index", attempt_index)
        |> then(&Wardwright.complete_selected_model(decision.selected_model, &1))
        |> Map.put_new(:structured_output, nil)
      end)
    end
  end

  defp require_messages(%{"messages" => messages}) when is_list(messages) and messages != [],
    do: :ok

  defp require_messages(_), do: {:error, "messages must not be empty"}

  defp require_protected_access(conn) do
    cond do
      local_request?(conn) ->
        :ok

      admin_token_valid?(conn) ->
        :ok

      Application.get_env(:wardwright, :allow_prototype_access, false) ->
        :ok

      true ->
        {:error, :protected, "protected endpoint requires localhost or admin token"}
    end
  end

  defp local_request?(%{remote_ip: {127, 0, 0, 1}}), do: true
  defp local_request?(%{remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}}), do: true
  defp local_request?(_conn), do: false

  defp admin_token_valid?(conn) do
    case {admin_token(), request_admin_token(conn)} do
      {token, request_token} when is_binary(token) and is_binary(request_token) ->
        Plug.Crypto.secure_compare(token, request_token)

      {_token, _request_token} ->
        false
    end
  rescue
    _error -> false
  end

  defp admin_token do
    (Application.get_env(:wardwright, :admin_token) || System.get_env("WARDWRIGHT_ADMIN_TOKEN"))
    |> metadata_string()
    |> blank_to_nil()
  end

  defp request_admin_token(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> bearer_token()
    |> case do
      nil ->
        conn
        |> get_req_header("x-wardwright-admin-token")
        |> List.first()
        |> metadata_string()
        |> blank_to_nil()

      token ->
        token
    end
  end

  defp bearer_token("Bearer " <> token), do: blank_to_nil(token)
  defp bearer_token("bearer " <> token), do: blank_to_nil(token)
  defp bearer_token(_value), do: nil

  defp route_decision(request, policy) do
    estimate = Wardwright.estimate_prompt_tokens(Map.get(request, "messages", []))
    Wardwright.select_route(estimate, Map.get(policy, "route_constraints", %{}))
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
        "strategy" => decision.combine_strategy,
        "route_type" => decision.route_type,
        "route_id" => decision.route_id,
        "selected_provider" => decision.selected_provider,
        "selected_model" => decision.selected_model,
        "selected_models" => decision.selected_models,
        "fallback_models" => decision.fallback_models,
        "fallback_used" => decision.fallback_used,
        "route_blocked" => decision.route_blocked,
        "policy_route_constraints" => decision.policy_route_constraints,
        "estimated_prompt_tokens" => decision.estimated_prompt_tokens,
        "skipped" => decision.skipped,
        "reason" => decision.reason,
        "rule" => decision.rule,
        "governance" => Wardwright.current_config()["governance"],
        "policy_actions" => policy["actions"],
        "policy_conflicts" => policy["conflicts"]
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
        "alert_delivery" => Map.get(policy, "alert_delivery", []),
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
      |> put_if_present("structured_output", Map.get(provider, :structured_output))
      |> put_if_present("stream_policy", stream_policy_receipt(Map.get(provider, :stream_policy)))
      |> put_stream_policy_summary(Map.get(provider, :stream_policy))
      |> put_if_present("provider_error", provider.error)
    end)
  end

  defp put_stream_policy_summary(final, nil), do: final

  defp put_stream_policy_summary(final, stream_policy) do
    final
    |> Map.put("stream_trigger_count", stream_policy.trigger_count)
    |> put_if_present("stream_policy_action", stream_policy.action)
  end

  defp stream_policy_receipt(nil), do: nil

  defp stream_policy_receipt(stream_policy) do
    %{
      "status" => stream_policy.status,
      "trigger_count" => stream_policy.trigger_count,
      "action" => stream_policy.action,
      "events" => stream_policy.events,
      "released_to_consumer" => stream_policy.released_to_consumer,
      "retry_count" => Map.get(stream_policy, :retry_count, 0),
      "max_retries" => Map.get(stream_policy, :max_retries, 0),
      "attempts" => Map.get(stream_policy, :attempts, []),
      "generated_bytes" => Map.get(stream_policy, :generated_bytes, 0),
      "released_bytes" => Map.get(stream_policy, :released_bytes, 0),
      "held_bytes" => Map.get(stream_policy, :held_bytes, 0),
      "rewritten_bytes" => Map.get(stream_policy, :rewritten_bytes, 0),
      "blocked_bytes" => Map.get(stream_policy, :blocked_bytes, 0)
    }
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
        "selected_model" => decision.selected_model,
        "status" => get_in(receipt, ["final", "status"]),
        "provider_error" => get_in(receipt, ["final", "provider_error"]),
        "structured_output" => get_in(receipt, ["final", "structured_output"]),
        "stream_policy" => get_in(receipt, ["final", "stream_policy"]),
        "alert_delivery" => get_in(receipt, ["final", "alert_delivery"])
      }
    }
  end

  defp response_status(receipt) do
    case get_in(receipt, ["final", "status"]) do
      status when status in ["completed", "completed_after_guard"] -> 200
      "policy_failed_closed" -> 429
      "provider_error" -> 502
      "exhausted_rule_budget" -> 422
      "exhausted_guard_budget" -> 422
      "stream_policy_blocked" -> 422
      "stream_policy_retry_required" -> 409
      _ -> 200
    end
  end

  defp stream_chat(conn, request, decision, chunks) do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    chunks = chunks || default_stream_chunks(request, decision)

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

  defp evaluate_stream_policy(request, decision) do
    rules = Wardwright.current_config()["stream_rules"] || []

    evaluate_stream_attempt(request, decision, rules, 0, 0, 0, [], [])
  end

  defp evaluate_stream_attempt(
         request,
         decision,
         rules,
         active_retry_budget,
         attempt_index,
         retry_count,
         events,
         attempts
       ) do
    case stream_chunks(request, decision, attempt_index) do
      {:ok, chunks, provider} ->
        policy = Wardwright.Policy.Stream.evaluate(chunks, rules, attempt_index: attempt_index)
        attempt = stream_attempt(policy, attempt_index, provider)
        events = events ++ policy.events
        attempts = attempts ++ [attempt]

        trigger_event = List.last(policy.events) || %{}
        retry_budget = stream_retry_budget(trigger_event, active_retry_budget)

        if policy.status == "stream_policy_retry_required" and retry_count < retry_budget do
          retry_event = %{
            "type" => "attempt.retry_requested",
            "attempt_index" => attempt_index,
            "next_attempt_index" => attempt_index + 1,
            "retry_count" => retry_count + 1,
            "max_retries" => retry_budget,
            "rule_id" => Map.get(trigger_event, "rule_id"),
            "reminder" => Map.get(trigger_event, "reminder")
          }

          evaluate_stream_attempt(
            request,
            decision,
            rules,
            retry_budget,
            attempt_index + 1,
            retry_count + 1,
            events ++ [reject_blank(retry_event)],
            attempts
          )
        else
          policy
          |> Map.put(:events, events)
          |> Map.put(:attempts, attempts)
          |> Map.put(:retry_count, retry_count)
          |> Map.put(:max_retries, retry_budget)
          |> Map.put(:called_provider, Map.get(provider, :called_provider, false))
          |> Map.put(:mock, Map.get(provider, :mock, true))
          |> Map.put(:provider_latency_ms, stream_latency_ms(attempts))
        end

      {:error, provider} ->
        provider_error_stream_policy(provider, retry_count, active_retry_budget, attempts)
    end
  end

  defp stream_attempt(policy, attempt_index, provider) do
    %{
      "attempt_index" => attempt_index,
      "status" => policy.status,
      "action" => policy.action,
      "trigger_count" => policy.trigger_count,
      "released_to_consumer" => policy.released_to_consumer,
      "called_provider" => Map.get(provider, :called_provider, false),
      "mock" => Map.get(provider, :mock, true),
      "provider_status" => Map.get(provider, :status),
      "provider_latency_ms" => Map.get(provider, :latency_ms),
      "generated_bytes" => policy.generated_bytes,
      "released_bytes" => policy.released_bytes,
      "held_bytes" => policy.held_bytes,
      "rewritten_bytes" => policy.rewritten_bytes,
      "blocked_bytes" => policy.blocked_bytes
    }
    |> reject_blank()
  end

  defp stream_retry_budget(%{"action" => action} = trigger_event, _active_retry_budget)
       when action in ["retry", "retry_with_reminder"] do
    trigger_event
    |> Map.get("max_retries", 1)
    |> integer_value()
    |> max(0)
  end

  defp stream_retry_budget(_trigger_event, active_retry_budget), do: active_retry_budget

  defp stream_chunks(request, decision, attempt_index) do
    mock_chunks =
      if allow_mock_stream_chunks?() do
        attempt_chunks = get_in(request, ["metadata", "mock_stream_attempt_chunks"])

        cond do
          is_list(attempt_chunks) and is_list(Enum.at(attempt_chunks, attempt_index)) ->
            Enum.at(attempt_chunks, attempt_index)

          attempt_index == 0 ->
            get_in(request, ["metadata", "mock_stream_chunks"])

          true ->
            nil
        end
      end

    case mock_chunks do
      chunks when is_list(chunks) and chunks != [] ->
        {:ok, Enum.map(chunks, &metadata_string/1),
         %{called_provider: false, mock: true, status: "completed", latency_ms: 0}}

      _ ->
        stream_request = Map.put(request, "wardwright_attempt_index", attempt_index)
        provider = Wardwright.stream_selected_model(decision.selected_model, stream_request)

        if provider.status == "completed" and is_list(Map.get(provider, :stream_chunks)) do
          {:ok, provider.stream_chunks,
           %{
             called_provider: provider.called_provider,
             mock: provider.mock,
             status: provider.status,
             latency_ms: provider.latency_ms
           }}
        else
          {:error, provider}
        end
    end
  end

  defp provider_error_stream_policy(provider, retry_count, max_retries, attempts) do
    attempts =
      attempts ++
        [
          %{
            "attempt_index" => length(attempts),
            "status" => "provider_error",
            "called_provider" => Map.get(provider, :called_provider, true),
            "mock" => Map.get(provider, :mock, false),
            "provider_status" => Map.get(provider, :status),
            "provider_latency_ms" => Map.get(provider, :latency_ms),
            "provider_error" => Map.get(provider, :error)
          }
          |> reject_blank()
        ]

    %{
      status: "provider_error",
      trigger_count: 0,
      action: nil,
      events: [],
      chunks: [],
      released_to_consumer: false,
      retry_count: retry_count,
      max_retries: max_retries,
      attempts: attempts,
      generated_bytes: sum_attempt_bytes(attempts, "generated_bytes"),
      released_bytes: sum_attempt_bytes(attempts, "released_bytes"),
      held_bytes: sum_attempt_bytes(attempts, "held_bytes"),
      rewritten_bytes: sum_attempt_bytes(attempts, "rewritten_bytes"),
      blocked_bytes: sum_attempt_bytes(attempts, "blocked_bytes"),
      called_provider: Map.get(provider, :called_provider, true),
      mock: Map.get(provider, :mock, false),
      provider_latency_ms: stream_latency_ms(attempts),
      provider_error: Map.get(provider, :error)
    }
  end

  defp stream_latency_ms(attempts) do
    Enum.reduce(attempts, 0, fn attempt, total ->
      total + (integer_value(Map.get(attempt, "provider_latency_ms")) || 0)
    end)
  end

  defp sum_attempt_bytes(attempts, key) do
    Enum.reduce(attempts, 0, fn attempt, total ->
      total + (integer_value(Map.get(attempt, key)) || 0)
    end)
  end

  defp allow_mock_stream_chunks? do
    Application.get_env(:wardwright, :allow_mock_stream_chunks, false)
  end

  defp default_stream_chunks(request, decision) do
    [
      "Mock Wardwright stream ",
      "routed to #{decision.selected_model} ",
      "for #{Map.get(request, "model")} with #{decision.estimated_prompt_tokens} estimated prompt tokens."
    ]
  end

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp reject_blank(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  defp test_config_allowed? do
    Application.get_env(:wardwright, :allow_test_config, false) or
      System.get_env("WARDWRIGHT_ALLOW_TEST_CONFIG") == "1"
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
