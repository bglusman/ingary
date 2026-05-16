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
    assert "propose_rule_change" in tool_names

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
