defmodule Wardwright.Router do
  @moduledoc false

  use Plug.Router

  @max_unpinned_key "max_unpinned"
  @regression_format_key "format"
  @json_format "json"

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
      caller = WardwrightWeb.RequestContext.caller(conn, Map.get(request, "metadata", %{}))
      tool_context_opts = WardwrightWeb.RequestContext.tool_context_opts(conn)
      Wardwright.Policy.History.record_request(caller, request, tool_context_opts)
      {request, policy} = apply_request_policies(request, caller, tool_context_opts)
      {policy, fail_closed?} = deliver_policy_alerts(policy)
      decision = route_decision(request, policy)

      record_runtime_event(model, caller, "route.selected", %{
        "selected_model" => decision.selected_model,
        "selected_provider" => decision.selected_provider,
        "estimated_prompt_tokens" => decision.estimated_prompt_tokens
      })

      if Map.get(request, "stream") == true and not fail_closed? and not decision.route_blocked do
        WardwrightWeb.StreamRuntime.run(conn, model, caller, request, decision, policy)
      else
        provider = provider_outcome(request, decision, fail_closed?)
        Wardwright.Policy.History.record_response(caller, provider.content)

        receipt =
          provider.status
          |> WardwrightWeb.ReceiptBuilder.build(
            model,
            caller,
            request,
            decision,
            provider.called_provider,
            policy
          )
          |> WardwrightWeb.ReceiptBuilder.apply_provider_outcome(provider)

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

        json(
          conn,
          WardwrightWeb.ReceiptBuilder.response_status(receipt),
          WardwrightWeb.ReceiptBuilder.chat_response(request, receipt, decision, provider.content)
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
      caller = WardwrightWeb.RequestContext.caller(conn, Map.get(request, "metadata", %{}))
      tool_context_opts = WardwrightWeb.RequestContext.tool_context_opts(conn)
      Wardwright.Policy.History.record_request(caller, request, tool_context_opts)
      {request, policy} = apply_request_policies(request, caller, tool_context_opts)
      {policy, fail_closed?} = deliver_policy_alerts(policy)
      decision = route_decision(request, policy)

      record_runtime_event(model, caller, "simulation.route_selected", %{
        "selected_model" => decision.selected_model,
        "selected_provider" => decision.selected_provider,
        "estimated_prompt_tokens" => decision.estimated_prompt_tokens
      })

      status =
        if fail_closed? or decision.route_blocked, do: "policy_failed_closed", else: "simulated"

      receipt =
        WardwrightWeb.ReceiptBuilder.build(
          status,
          model,
          caller,
          request,
          decision,
          false,
          policy
        )

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
          "tool_namespace",
          "tool_name",
          "tool_phase",
          "tool_policy_status",
          "tool_risk_class",
          "tool_source",
          "tool_call_id",
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
        "kind" => WardwrightWeb.RequestContext.blank_to_nil(Map.get(conn.query_params, "kind")),
        "key" => WardwrightWeb.RequestContext.blank_to_nil(Map.get(conn.query_params, "key")),
        "scope" => WardwrightWeb.RequestContext.cache_scope_from_query(conn.query_params)
      }

      limit = parse_limit(Map.get(conn.query_params, "limit"))
      json(conn, 200, %{"data" => Wardwright.PolicyCache.recent(filter, limit)})
    else
      {:error, :protected, message} ->
        error(conn, 403, message, "forbidden", "protected_endpoint")
    end
  end

  get "/v1/policy-authoring/tools" do
    with :ok <- require_protected_access(conn) do
      json(conn, 200, Map.new([{"data", WardwrightWeb.PolicyAuthoringTools.list()}]))
    else
      {:error, :protected, message} ->
        error(conn, 403, message, "forbidden", "protected_endpoint")
    end
  end

  get "/v1/policy-authoring/projections/:pattern_id" do
    with :ok <- require_protected_access(conn),
         :ok <- require_known_policy_pattern(pattern_id) do
      json(
        conn,
        200,
        Map.new([{"projection", Wardwright.PolicyProjection.projection(pattern_id)}])
      )
    else
      {:error, :protected, message} ->
        error(conn, 403, message, "forbidden", "protected_endpoint")

      {:error, message} ->
        error(conn, 404, message, "not_found", "policy_pattern_not_found")
    end
  end

  get "/v1/policy-authoring/simulations/:pattern_id" do
    with :ok <- require_protected_access(conn),
         :ok <- require_known_policy_pattern(pattern_id) do
      json(conn, 200, Map.new([{"data", Wardwright.PolicyProjection.simulations(pattern_id)}]))
    else
      {:error, :protected, message} ->
        error(conn, 403, message, "forbidden", "protected_endpoint")

      {:error, message} ->
        error(conn, 404, message, "not_found", "policy_pattern_not_found")
    end
  end

  get "/v1/policy-authoring/scenarios/:pattern_id" do
    with :ok <- require_protected_access(conn),
         true <- known_policy_pattern?(pattern_id) do
      scenarios =
        pattern_id
        |> Wardwright.PolicyScenarioStore.list()
        |> Enum.map(&Wardwright.PolicyScenario.to_map/1)

      json(conn, 200, Map.new([{"data", scenarios}]))
    else
      {:error, :protected, message} ->
        error(conn, 403, message, "forbidden", "protected_endpoint")

      false ->
        error(conn, 404, "policy pattern not found", "not_found", "policy_pattern_not_found")
    end
  end

  post "/v1/policy-authoring/scenarios/:pattern_id" do
    with :ok <- require_protected_access(conn),
         true <- known_policy_pattern?(pattern_id),
         {:ok, body} <- require_json_object(conn.body_params),
         {:ok, scenario_body} <- scenario_payload(body),
         {:ok, scenario} <- Wardwright.PolicyScenarioStore.create(pattern_id, scenario_body) do
      json(conn, 201, Map.new([{"scenario", Wardwright.PolicyScenario.to_map(scenario)}]))
    else
      {:error, :protected, message} ->
        error(conn, 403, message, "forbidden", "protected_endpoint")

      false ->
        error(conn, 404, "policy pattern not found", "not_found", "policy_pattern_not_found")

      {:error, message} when is_binary(message) ->
        error(conn, 400, message, "invalid_request", "invalid_policy_scenario")
    end
  end

  post "/v1/policy-authoring/scenarios/:pattern_id/from-receipt/:receipt_id" do
    with :ok <- require_protected_access(conn),
         true <- known_policy_pattern?(pattern_id),
         {:ok, body} <- require_json_object(conn.body_params),
         {:ok, receipt} <- receipt_for_import(receipt_id),
         {:ok, scenario} <-
           Wardwright.PolicyScenarioStore.create_from_receipt(pattern_id, receipt, body) do
      json(conn, 201, Map.new([{"scenario", Wardwright.PolicyScenario.to_map(scenario)}]))
    else
      {:error, :protected, message} ->
        error(conn, 403, message, "forbidden", "protected_endpoint")

      false ->
        error(conn, 404, "policy pattern not found", "not_found", "policy_pattern_not_found")

      {:error, :receipt_not_found} ->
        error(conn, 404, "receipt not found", "not_found", "receipt_not_found")

      {:error, message} when is_binary(message) ->
        error(conn, 400, message, "invalid_request", "invalid_policy_scenario")
    end
  end

  get "/v1/policy-authoring/scenarios/:pattern_id/regression-export" do
    with :ok <- require_protected_access(conn),
         true <- known_policy_pattern?(pattern_id),
         {:ok, export} <- Wardwright.PolicyScenarioStore.regression_export(pattern_id) do
      format = Map.get(conn.query_params, @regression_format_key, @json_format)

      case format do
        @json_format ->
          json(conn, 200, export)

        "exunit" ->
          case WardwrightWeb.PolicyScenarioRegression.exunit_source(export) do
            {:ok, source} ->
              text(conn, 200, source)

            {:error, message} ->
              error(conn, 400, message, "invalid_request", "invalid_regression_export")
          end

        other ->
          error(
            conn,
            400,
            "unsupported regression export format #{inspect(other)}",
            "invalid_request",
            "invalid_regression_export_format"
          )
      end
    else
      {:error, :protected, message} ->
        error(conn, 403, message, "forbidden", "protected_endpoint")

      false ->
        error(conn, 404, "policy pattern not found", "not_found", "policy_pattern_not_found")

      {:error, message} when is_binary(message) ->
        error(conn, 400, message, "invalid_request", "invalid_regression_export")
    end
  end

  post "/v1/policy-authoring/scenarios/:pattern_id/retention" do
    with :ok <- require_protected_access(conn),
         true <- known_policy_pattern?(pattern_id),
         {:ok, body} <- require_json_object(conn.body_params),
         {:ok, max_unpinned} <- retention_max_unpinned(body),
         {:ok, retention} <-
           Wardwright.PolicyScenarioStore.enforce_retention(pattern_id, max_unpinned) do
      json(conn, 200, retention)
    else
      {:error, :protected, message} ->
        error(conn, 403, message, "forbidden", "protected_endpoint")

      false ->
        error(conn, 404, "policy pattern not found", "not_found", "policy_pattern_not_found")

      {:error, message} when is_binary(message) ->
        error(conn, 400, message, "invalid_request", "invalid_policy_scenario_retention")
    end
  end

  post "/v1/policy-authoring/validate" do
    with :ok <- require_protected_access(conn),
         {:ok, artifact, source} <- validation_artifact(conn.body_params) do
      json(conn, 200, WardwrightWeb.PolicyArtifactValidator.validate(artifact, source: source))
    else
      {:error, :protected, message} ->
        error(conn, 403, message, "forbidden", "protected_endpoint")

      {:error, message} ->
        error(conn, 400, message, "invalid_request", "invalid_policy_artifact")
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
        Wardwright.PolicyScenarioStore.clear()

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

  defp scenario_payload(body) do
    # boundary-map-ok
    case Map.fetch(body, "scenario") do
      {:ok, scenario} when is_map(scenario) -> {:ok, scenario}
      {:ok, _scenario} -> {:error, "scenario must be a JSON object"}
      :error -> {:ok, body}
    end
  end

  defp receipt_for_import(receipt_id) do
    case Wardwright.ReceiptStore.get(receipt_id) do
      nil -> {:error, :receipt_not_found}
      receipt -> {:ok, receipt}
    end
  end

  defp validation_artifact(body) when body == %{},
    do: {:ok, Wardwright.current_config(), "current_config"}

  defp validation_artifact(body) when is_map(body) do
    # boundary-map-ok
    case Map.fetch(body, "artifact") do
      {:ok, artifact} when is_map(artifact) -> {:ok, artifact, "submitted"}
      {:ok, _artifact} -> {:error, "artifact must be a JSON object"}
      :error -> {:ok, body, "submitted"}
    end
  end

  defp validation_artifact(_body), do: {:error, "request body must be a JSON object"}

  defp retention_max_unpinned(body) do
    case Map.get(body, @max_unpinned_key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _value -> {:error, "max_unpinned must be a non-negative integer"}
    end
  end

  defp override_model(request, nil), do: request
  defp override_model(request, ""), do: request
  defp override_model(request, model), do: Map.put(request, "model", model)

  defp apply_prompt_transforms(request) do
    transforms = Wardwright.current_config()["prompt_transforms"] || %{}
    messages = Map.get(request, "messages", [])

    messages =
      case transforms["preamble"]
           |> WardwrightWeb.RequestContext.metadata_string()
           |> WardwrightWeb.RequestContext.blank_to_nil() do
        nil ->
          messages

        text ->
          [%{"role" => "system", "name" => "wardwright_preamble", "content" => text} | messages]
      end

    messages =
      case transforms["postscript"]
           |> WardwrightWeb.RequestContext.metadata_string()
           |> WardwrightWeb.RequestContext.blank_to_nil() do
        nil ->
          messages

        text ->
          messages ++
            [%{"role" => "system", "name" => "wardwright_postscript", "content" => text}]
      end

    Map.put(request, "messages", messages)
  end

  defp apply_request_policies(request, caller, opts),
    do:
      Wardwright.Policy.Plan.evaluate_request(request, caller, Wardwright.current_config(), opts)

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
    structured_config = Wardwright.current_config()["structured_output"]

    Wardwright.Policy.StructuredOutput.run(structured_config, fn attempt_index ->
      request
      |> Map.put("wardwright_attempt_index", attempt_index)
      |> then(&Wardwright.complete_selected_model(decision.selected_model, &1))
      |> Map.put_new(:structured_output, nil)
    end)
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
    |> WardwrightWeb.RequestContext.metadata_string()
    |> WardwrightWeb.RequestContext.blank_to_nil()
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
        |> WardwrightWeb.RequestContext.metadata_string()
        |> WardwrightWeb.RequestContext.blank_to_nil()

      token ->
        token
    end
  end

  defp bearer_token("Bearer " <> token), do: WardwrightWeb.RequestContext.blank_to_nil(token)
  defp bearer_token("bearer " <> token), do: WardwrightWeb.RequestContext.blank_to_nil(token)
  defp bearer_token(_value), do: nil

  defp route_decision(request, policy) do
    estimate = Wardwright.estimate_prompt_tokens(Map.get(request, "messages", []))
    Wardwright.select_route(estimate, Map.get(policy, "route_constraints", %{}))
  end

  defp record_runtime_event(model, caller, type, fields) do
    version = Wardwright.current_config()["version"]

    case Wardwright.Runtime.record_session_event(
           model,
           version,
           WardwrightWeb.RequestContext.session_id(caller),
           type,
           fields
         ) do
      {:ok, _event} -> :ok
      _ -> :ok
    end
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

  defp text(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end

  defp cors(conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, POST, OPTIONS")
    |> put_resp_header(
      "access-control-allow-headers",
      "Authorization, Content-Type, X-Wardwright-Admin-Token, X-Wardwright-Tenant-Id, X-Wardwright-Application-Id, X-Wardwright-Agent-Id, X-Wardwright-User-Id, X-Wardwright-Session-Id, X-Wardwright-Run-Id, X-Client-Request-Id"
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

  defp require_known_policy_pattern(pattern_id) do
    if known_policy_pattern?(pattern_id) do
      :ok
    else
      {:error, "policy pattern not found"}
    end
  end

  defp known_policy_pattern?(pattern_id),
    do: pattern_id in Wardwright.PolicyProjection.pattern_ids()
end
