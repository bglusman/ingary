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
          Map.has_key?(rule, "engine") ->
            apply_engine_governance_rule(rule, caller, request, policy)

          kind == "history_threshold" ->
            apply_history_threshold_rule(rule, caller, request, policy)

          kind == "history_regex_threshold" ->
            apply_history_regex_threshold_rule(rule, caller, request, policy)

          kind in ["request_guard", "request_transform", "receipt_annotation", "route_gate"] &&
              policy_rule_matches?(text, rule) ->
            action = Map.get(rule, "action", "annotate")
            rule_id = Map.get(rule, "id", "policy")

            message =
              rule |> Map.get("message", "request policy matched") |> blank_to_nil() ||
                "request policy matched"

            severity = rule |> Map.get("severity", "info") |> blank_to_nil() || "info"

            action_record =
              %{
                "rule_id" => rule_id,
                "kind" => kind,
                "action" => action,
                "matched" => true,
                "message" => message,
                "severity" => severity
              }
              |> put_route_action_fields(rule)

            case action do
              action when action in ["escalate", "alert_async"] ->
                event = %{
                  "type" => "policy.alert",
                  "rule_id" => rule_id,
                  "message" => message,
                  "severity" => severity,
                  "idempotency_key" => Map.get(rule, "idempotency_key")
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

              action when action in ["restrict_routes", "switch_model", "reroute"] ->
                apply_route_action(request, policy, action_record)

              "block" ->
                apply_block_action(request, policy, action_record)

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

  defp empty_policy,
    do: %{
      "actions" => [],
      "events" => [],
      "alert_count" => 0,
      "route_constraints" => %{},
      "blocked" => false
    }

  defp apply_engine_governance_rule(rule, caller, request, policy) do
    context = %{
      "request_text" => request |> Map.get("messages", []) |> request_text(),
      "request" => request,
      "caller" => caller,
      "estimated_prompt_tokens" =>
        Wardwright.estimate_prompt_tokens(Map.get(request, "messages", []))
    }

    result = Wardwright.Policy.Engine.evaluate(rule, context)

    action_records =
      result
      |> engine_actions(rule)
      |> Enum.map(&put_route_action_fields/1)

    Enum.reduce(action_records, {request, policy}, fn action_record, {request, policy} ->
      case action_record["action"] do
        action when action in ["restrict_routes", "switch_model", "reroute"] ->
          apply_route_action(request, policy, action_record)

        "block" ->
          apply_block_action(request, policy, action_record)

        _ ->
          {request, Map.update!(policy, "actions", &[action_record | &1])}
      end
    end)
  end

  defp engine_actions(%{"actions" => actions}, rule) when is_list(actions) do
    Enum.map(actions, &engine_action_record(&1, rule))
  end

  defp engine_actions(%{"action" => action} = result, rule) when is_binary(action) do
    [engine_action_record(result, rule)]
  end

  defp engine_actions(_result, _rule), do: []

  defp engine_action_record(action, rule) when is_map(action) do
    value = Map.get(action, "value", %{})
    value = if is_map(value), do: value, else: %{}

    %{
      "rule_id" => Map.get(action, "rule_id", Map.get(rule, "id", "policy-engine")),
      "kind" => Map.get(rule, "kind", "policy_engine"),
      "action" => Map.get(action, "action", "annotate"),
      "matched" => Map.get(action, "matched", true),
      "message" =>
        Map.get(
          action,
          "message",
          Map.get(action, "reason", Map.get(value, "reason", "policy engine matched"))
        ),
      "severity" => Map.get(action, "severity", "info"),
      "allowed_targets" => Map.get(action, "allowed_targets", Map.get(value, "allowed_targets")),
      "target_model" =>
        Map.get(
          action,
          "target_model",
          Map.get(action, "model", Map.get(value, "target_model", Map.get(value, "model")))
        )
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  defp engine_action_record(_action, rule) do
    %{
      "rule_id" => Map.get(rule, "id", "policy-engine"),
      "kind" => Map.get(rule, "kind", "policy_engine"),
      "action" => "annotate",
      "matched" => true,
      "message" => "policy engine returned a non-map action",
      "severity" => "warning"
    }
  end

  defp apply_route_action(request, policy, action_record) do
    route_constraints =
      policy
      |> Map.get("route_constraints", %{})
      |> merge_route_constraints(action_record)

    policy =
      policy
      |> Map.put("route_constraints", route_constraints)
      |> Map.update!("actions", &[action_record | &1])

    {request, policy}
  end

  defp merge_route_constraints(route_constraints, %{"action" => "restrict_routes"} = action) do
    allowed_targets = normalize_string_list(Map.get(action, "allowed_targets"))

    if allowed_targets == [] do
      route_constraints
    else
      Map.update(route_constraints, "allowed_targets", allowed_targets, fn existing ->
        existing
        |> normalize_string_list()
        |> Enum.filter(&(&1 in allowed_targets))
      end)
    end
  end

  defp merge_route_constraints(route_constraints, %{"action" => action} = record)
       when action in ["switch_model", "reroute"] do
    target_model = record |> Map.get("target_model", Map.get(record, "model")) |> blank_to_nil()

    if target_model do
      Map.put(route_constraints, "forced_model", target_model)
    else
      route_constraints
    end
  end

  defp merge_route_constraints(route_constraints, _action), do: route_constraints

  defp apply_block_action(request, policy, action_record) do
    policy =
      policy
      |> Map.put("blocked", true)
      |> Map.update!("actions", &[action_record | &1])

    {request, policy}
  end

  defp put_route_action_fields(action_record, rule) do
    action_record
    |> maybe_put_string_list("allowed_targets", Map.get(rule, "allowed_targets"))
    |> maybe_put_string("target_model", Map.get(rule, "target_model", Map.get(rule, "model")))
  end

  defp put_route_action_fields(action_record),
    do: put_route_action_fields(action_record, action_record)

  defp maybe_put_string_list(map, key, value) do
    value = normalize_string_list(value)
    if value == [], do: map, else: Map.put(map, key, value)
  end

  defp maybe_put_string(map, key, value) do
    case blank_to_nil(value) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_string_list(_values), do: []

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

      if action in ["escalate", "alert_async"] do
        event = %{
          "type" => "policy.alert",
          "rule_id" => rule_id,
          "message" => message,
          "severity" => severity,
          "history_count" => count,
          "threshold" => threshold,
          "idempotency_key" => Map.get(rule, "idempotency_key")
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

  defp apply_history_regex_threshold_rule(rule, caller, request, policy) do
    threshold = max(1, integer_value(Map.get(rule, "threshold", 1)) || 1)

    filter = %{
      "kind" => blank_to_nil(Map.get(rule, "cache_kind")),
      "key" => blank_to_nil(Map.get(rule, "cache_key")),
      "scope" => cache_scope_from_caller(caller, Map.get(rule, "cache_scope", ""))
    }

    count =
      filter
      |> Wardwright.Policy.History.regex_count(
        Map.get(rule, "pattern", ""),
        Map.get(rule, "limit")
      )

    if count < threshold do
      {request, policy}
    else
      action = Map.get(rule, "action", "annotate")
      rule_id = Map.get(rule, "id", "policy")

      message =
        rule |> Map.get("message", "history regex threshold matched") |> blank_to_nil() ||
          "history regex threshold matched"

      severity = rule |> Map.get("severity", "info") |> blank_to_nil() || "info"

      action_record = %{
        "rule_id" => rule_id,
        "kind" => "history_regex_threshold",
        "action" => action,
        "matched" => true,
        "message" => message,
        "severity" => severity,
        "cache_kind" => Map.get(rule, "cache_kind", ""),
        "cache_key" => Map.get(rule, "cache_key", ""),
        "cache_scope" => Map.get(rule, "cache_scope", ""),
        "pattern" => Map.get(rule, "pattern", ""),
        "history_count" => count,
        "threshold" => threshold
      }

      policy = Map.update!(policy, "actions", &[action_record | &1])

      if action in ["escalate", "alert_async"] do
        event = %{
          "type" => "policy.alert",
          "rule_id" => rule_id,
          "message" => message,
          "severity" => severity,
          "history_count" => count,
          "threshold" => threshold,
          "idempotency_key" => Map.get(rule, "idempotency_key")
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
      stream_policy =
        request
        |> stream_chunks(decision)
        |> Wardwright.Policy.Stream.evaluate(Wardwright.current_config()["stream_rules"] || [])

      %{
        content: nil,
        status: stream_policy.status,
        latency_ms: 0,
        error: nil,
        called_provider: false,
        mock: true,
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

  defp policy_match?(_text, value) when value in [nil, ""], do: false

  defp policy_match?(text, value) do
    String.contains?(text, value |> metadata_string() |> String.downcase())
  end

  defp policy_rule_matches?(text, %{"regex" => regex}) when is_binary(regex) and regex != "" do
    Wardwright.Policy.Regex.match?(text, regex)
  end

  defp policy_rule_matches?(text, rule), do: policy_match?(text, Map.get(rule, "contains"))

  defp request_text(messages) when is_list(messages) do
    Enum.map_join(messages, "\n", fn message ->
      "#{Map.get(message, "role", "")}\n#{metadata_string(Map.get(message, "content"))}"
    end)
  end

  defp request_text(_), do: ""

  defp require_messages(%{"messages" => messages}) when is_list(messages) and messages != [],
    do: :ok

  defp require_messages(_), do: {:error, "messages must not be empty"}

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
      "released_to_consumer" => stream_policy.released_to_consumer
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

    chunks = chunks || stream_chunks(request, decision)

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

  defp stream_chunks(request, decision) do
    mock_chunks =
      if allow_mock_stream_chunks?(), do: get_in(request, ["metadata", "mock_stream_chunks"])

    case mock_chunks do
      chunks when is_list(chunks) and chunks != [] ->
        Enum.map(chunks, &metadata_string/1)

      _ ->
        [
          "Mock Wardwright stream ",
          "routed to #{decision.selected_model} ",
          "for #{Map.get(request, "model")} with #{decision.estimated_prompt_tokens} estimated prompt tokens."
        ]
    end
  end

  defp allow_mock_stream_chunks? do
    Application.get_env(:wardwright, :allow_mock_stream_chunks, false)
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
