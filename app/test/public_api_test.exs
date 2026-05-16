defmodule Wardwright.PublicApiTest do
  use Wardwright.RouterCase

  test "lists flat and prefixed public models" do
    conn = call(:get, "/v1/models")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert Enum.map(body["data"], & &1["id"]) == ["coding-balanced", "wardwright/coding-balanced"]
  end

  test "public synthetic model discovery omits policy internals" do
    config =
      unit_policy_config()
      |> Map.put("prompt_transforms", %{"preamble" => "private operator prompt"})
      |> Map.put("governance", [
        %{"id" => "internal-policy", "kind" => "request_guard", "contains" => "secret marker"}
      ])

    assert call(:post, "/__test/config", config).status == 200

    conn = call(:get, "/v1/synthetic/models")
    assert conn.status == 200

    [model] = Jason.decode!(conn.resp_body)["data"]
    assert model["id"] == "unit-model"
    assert model["active_version"] == "unit-version"
    assert model["route_type"] == "dispatcher"

    refute Map.has_key?(model, "governance")
    refute Map.has_key?(model, "prompt_transforms")
    refute Map.has_key?(model, "route_graph")
    refute Map.has_key?(model, "structured_output")
  end

  test "admin synthetic model endpoint keeps full policy record behind protection" do
    config =
      unit_policy_config()
      |> Map.put("prompt_transforms", %{"preamble" => "private operator prompt"})

    assert call(:post, "/__test/config", config).status == 200

    rejected = call(:get, "/admin/synthetic-models", nil, [], {203, 0, 113, 10})
    assert rejected.status == 403

    local = call(:get, "/admin/synthetic-models")
    assert local.status == 200

    [model] = Jason.decode!(local.resp_body)["data"]
    assert model["prompt_transforms"] == %{"preamble" => "private operator prompt"}
    assert is_list(model["governance"])
    assert is_map(model["route_graph"])
  end

  test "protected policy authoring API exposes projection and tool contracts" do
    rejected = call(:get, "/v1/policy-authoring/tools", nil, [], {203, 0, 113, 10})
    assert rejected.status == 403

    tools = call(:get, "/v1/policy-authoring/tools")
    assert tools.status == 200

    tool_names =
      tools.resp_body |> Jason.decode!() |> Map.fetch!("data") |> Enum.map(& &1["name"])

    assert "explain_projection" in tool_names
    assert "simulate_policy" in tool_names
    assert "record_scenario" in tool_names
    assert "propose_rule_change" in tool_names
    assert "validate_policy_artifact" in tool_names

    projection = call(:get, "/v1/policy-authoring/projections/tts-retry")
    assert projection.status == 200

    body = Jason.decode!(projection.resp_body)
    assert get_in(body, ["projection", "state_machine", "initial_state"]) == "observing"

    simulations = call(:get, "/v1/policy-authoring/simulations/tts-retry")
    assert simulations.status == 200

    assert [%{"artifact_hash" => "sha256:" <> _hash}] =
             Jason.decode!(simulations.resp_body)["data"]

    missing = call(:get, "/v1/policy-authoring/projections/not-real")
    assert missing.status == 404
  end

  test "protected policy authoring API persists scenarios for simulation evidence" do
    rejected =
      call(:post, "/v1/policy-authoring/scenarios/tts-retry", %{}, [], {203, 0, 113, 10})

    assert rejected.status == 403

    scenario = %{
      "scenario_id" => "api-reviewed-trigger",
      "title" => "API reviewed trigger",
      "source" => "user",
      "pinned" => true,
      "input_summary" => "A reviewed stream scenario stores the split trigger.",
      "expected_behavior" => "The stream retry rule fires before release.",
      "verdict" => "passed",
      "trace" => [
        %{
          "id" => "api-1",
          "phase" => "response.streaming",
          "node_id" => "tts.no-old-client",
          "kind" => "match",
          "label" => "persisted trace",
          "detail" => "scenario came from the authoring API",
          "severity" => "pass",
          "state_id" => "guarding"
        }
      ],
      "receipt_preview" => %{"final_status" => "simulated"}
    }

    created = call(:post, "/v1/policy-authoring/scenarios/tts-retry", %{"scenario" => scenario})
    assert created.status == 201

    created_body = Jason.decode!(created.resp_body)
    assert get_in(created_body, ["scenario", "scenario_id"]) == "api-reviewed-trigger"
    assert get_in(created_body, ["scenario", "scenario_source"]) == "persisted"

    listed = call(:get, "/v1/policy-authoring/scenarios/tts-retry")
    assert listed.status == 200
    assert [%{"scenario_id" => "api-reviewed-trigger"}] = Jason.decode!(listed.resp_body)["data"]

    simulations = call(:get, "/v1/policy-authoring/simulations/tts-retry")
    assert simulations.status == 200

    assert [
             %{
               "scenario_id" => "api-reviewed-trigger",
               "scenario_source" => "persisted",
               "artifact_hash" => "sha256:" <> _hash
             }
           ] = Jason.decode!(simulations.resp_body)["data"]

    malformed = call(:post, "/v1/policy-authoring/scenarios/tts-retry", %{"trace" => []})
    assert malformed.status == 400

    invalid_state =
      put_in(scenario, ["trace", Access.at(0), "state_id"], "not-a-state")

    invalid_state_conn =
      call(:post, "/v1/policy-authoring/scenarios/tts-retry", %{"scenario" => invalid_state})

    assert invalid_state_conn.status == 400
    assert get_in(Jason.decode!(invalid_state_conn.resp_body), ["error", "message"]) =~ "state_id"

    invalid_trace =
      put_in(scenario, ["trace", Access.at(0), "label"], "")

    invalid_trace_conn =
      call(:post, "/v1/policy-authoring/scenarios/tts-retry", %{"scenario" => invalid_trace})

    assert invalid_trace_conn.status == 400

    assert get_in(Jason.decode!(invalid_trace_conn.resp_body), ["error", "message"]) =~
             "trace event"

    invalid_source =
      Map.put(scenario, "source", "not-reviewed")

    invalid_source_conn =
      call(:post, "/v1/policy-authoring/scenarios/tts-retry", %{"scenario" => invalid_source})

    assert invalid_source_conn.status == 400

    assert get_in(Jason.decode!(invalid_source_conn.resp_body), ["error", "message"]) =~
             "source"

    missing = call(:post, "/v1/policy-authoring/scenarios/not-real", %{"scenario" => scenario})
    assert missing.status == 404
  end

  test "protected policy validation reports errors and explicit review gaps" do
    rejected =
      call(:post, "/v1/policy-authoring/validate", %{}, [], {203, 0, 113, 10})

    assert rejected.status == 403

    current = call(:post, "/v1/policy-authoring/validate", %{})
    assert current.status == 200

    current_body = Jason.decode!(current.resp_body)
    assert current_body["schema"] == "wardwright.policy_validation.v1"
    assert current_body["source"] == "current_config"
    assert current_body["verdict"] in ["valid", "needs_review"]
    assert Enum.any?(current_body["coverage_gaps"], &(&1["path"] == "scenarios"))

    invalid_artifact =
      unit_policy_config()
      |> Map.put("targets", [
        %{"model" => "tiny/model", "context_window" => 8},
        %{"model" => "tiny/model", "context_window" => 32}
      ])
      |> Map.put("dispatchers", [%{"id" => "dispatcher.good", "models" => ["tiny/model"]}])
      |> Map.put("route_root", "missing.selector")

    invalid = call(:post, "/v1/policy-authoring/validate", %{"artifact" => invalid_artifact})
    assert invalid.status == 200

    body = Jason.decode!(invalid.resp_body)
    assert body["source"] == "submitted"
    assert body["verdict"] == "invalid"
    assert Enum.any?(body["errors"], &(&1["message"] =~ "duplicate target tiny/model"))
    assert Enum.any?(body["errors"], &(&1["path"] == "route_root"))

    malformed_selector =
      unit_policy_config()
      |> Map.put("dispatchers", "not-a-list")

    malformed = call(:post, "/v1/policy-authoring/validate", %{"artifact" => malformed_selector})
    assert malformed.status == 200

    malformed_body = Jason.decode!(malformed.resp_body)
    assert malformed_body["verdict"] == "invalid"
    assert Enum.any?(malformed_body["errors"], &(&1["path"] == "dispatchers"))
  end

  test "chat completion records caller headers and selected model" do
    request = %{
      model: "wardwright/coding-balanced",
      messages: [%{role: "user", content: "hello"}],
      metadata: %{consuming_agent_id: "body-agent"}
    }

    conn =
      :post
      |> call("/v1/chat/completions", request, [{"x-wardwright-agent-id", "header-agent"}])

    assert conn.status == 200
    assert get_resp_header(conn, "x-wardwright-selected-model") == ["local/qwen-coder"]
    [receipt_id] = get_resp_header(conn, "x-wardwright-receipt-id")

    receipt = Wardwright.ReceiptStore.get(receipt_id)

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
end
