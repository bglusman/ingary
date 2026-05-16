defmodule Wardwright.PolicyProjectionLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint WardwrightWeb.Endpoint

  setup_all do
    original_config = Application.get_env(:wardwright, WardwrightWeb.Endpoint, [])

    endpoint_config =
      Keyword.merge(original_config,
        http: [ip: {127, 0, 0, 1}, port: 0],
        server: false,
        secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64))
      )

    Application.put_env(:wardwright, WardwrightWeb.Endpoint, endpoint_config)
    start_supervised!(WardwrightWeb.Endpoint)

    on_exit(fn ->
      Application.put_env(:wardwright, WardwrightWeb.Endpoint, original_config)
    end)

    :ok
  end

  setup do
    Wardwright.reset_config()
    Wardwright.ReceiptStore.clear()
    Wardwright.PolicyScenarioStore.clear()
    Wardwright.PolicyCache.reset()
    :ok
  end

  test "policy projection exposes stable review fields and confidence classes" do
    :ok = put_route_gate_config()
    projection = Wardwright.PolicyProjection.projection("route-privacy")

    assert projection["projection_schema"] == "wardwright.policy_projection.v1"
    assert projection["engine"]["language"] == "structured"
    assert projection["artifact"]["artifact_hash"] =~ "sha256:"
    assert projection["compiled_plan"]["planner"] == "Wardwright.Policy.Plan"
    assert projection["state_machine"]["schema"] == "wardwright.policy_state_machine.v1"
    assert projection["state_machine"]["default_projection"] == true
    assert [%{"id" => "active", "node_ids" => node_ids}] = projection["state_machine"]["states"]

    nodes = projection["phases"] |> Enum.flat_map(& &1["nodes"])
    assert Enum.any?(nodes, &(&1["id"] == "request-policy.private-route-gate"))
    assert Enum.any?(nodes, &(&1["confidence"] == "exact"))
    assert Enum.all?(nodes, &is_binary(&1["node_class"]))
    assert "request-policy.private-route-gate" in node_ids
    assert [%{"class" => "ordered"}] = projection["conflicts"]
  end

  test "simulation traces link execution evidence back to projection nodes" do
    projection = Wardwright.PolicyProjection.projection("tts-retry")
    node_ids = projection["phases"] |> Enum.flat_map(& &1["nodes"]) |> MapSet.new(& &1["id"])

    [simulation | _] = Wardwright.PolicyProjection.simulations("tts-retry")

    assert simulation["artifact_hash"] == projection["artifact"]["artifact_hash"]
    assert simulation["verdict"] in ["passed", "failed", "inconclusive"]
    assert Enum.any?(simulation["trace"], &MapSet.member?(node_ids, &1["node_id"]))
    assert Enum.all?(simulation["trace"], &is_binary(&1["state_id"]))
    assert is_map(simulation["receipt_preview"])

    assert projection["state_machine"]["default_projection"] == false
    state_ids = projection["state_machine"]["states"] |> MapSet.new(& &1["id"])

    assert Enum.map(projection["state_machine"]["states"], & &1["id"]) == [
             "observing",
             "guarding",
             "retrying",
             "recording"
           ]

    assert Enum.map(projection["state_machine"]["simulation_steps"], & &1["state"]) == [
             "observing",
             "guarding",
             "retrying",
             "recording"
           ]

    assert Enum.all?(
             projection["state_machine"]["simulation_steps"],
             &MapSet.member?(state_ids, &1["state"])
           )
  end

  test "projection simulations prefer persisted reviewed scenarios over fixtures" do
    assert {:ok, _scenario} =
             Wardwright.PolicyScenarioStore.create("tts-retry", %{
               "scenario_id" => "reviewed-split-trigger",
               "title" => "Reviewed split trigger",
               "source" => "assistant",
               "pinned" => true,
               "input_summary" => "Reviewed request keeps OldClient split across stream chunks.",
               "expected_behavior" =>
                 "Retry is requested before any violating bytes are released.",
               "verdict" => "passed",
               "trace" => [
                 %{
                   "id" => "r1",
                   "phase" => "response.streaming",
                   "node_id" => "tts.no-old-client",
                   "kind" => "match",
                   "label" => "reviewed match",
                   "detail" => "persisted scenario hit the stream rule",
                   "severity" => "pass",
                   "state_id" => "guarding"
                 }
               ],
               "receipt_preview" => %{"final_status" => "simulated"}
             })

    [simulation] = Wardwright.PolicyProjection.simulations("tts-retry")
    projection = Wardwright.PolicyProjection.projection("tts-retry")

    assert simulation["scenario_id"] == "reviewed-split-trigger"
    assert simulation["scenario_source"] == "persisted"
    assert simulation["source"] == "assistant"
    assert simulation["pinned"] == true
    assert simulation["artifact_hash"] == projection["artifact"]["artifact_hash"]
    assert get_in(simulation, ["trace", Access.at(0), "state_id"]) == "guarding"

    assert Enum.map(projection["state_machine"]["simulation_steps"], & &1["state"]) == [
             "guarding"
           ]
  end

  test "route projection simulation is derived from configured policy plan actions" do
    :ok = put_route_gate_config()
    [simulation] = Wardwright.PolicyProjection.simulations("route-privacy")

    assert simulation["scenario_id"] == "configured-route-policy"
    assert simulation["verdict"] == "passed"

    assert [
             %{
               "rule_id" => "private-route-gate",
               "action" => "restrict_routes",
               "allowed_targets" => [local_model]
             }
           ] = get_in(simulation, ["receipt_preview", "decision", "policy_actions"])

    assert local_model == Wardwright.local_model()

    assert %{"allowed_targets" => [^local_model]} =
             get_in(simulation, ["receipt_preview", "decision", "route_constraints"])
  end

  test "tool governance projection exposes tool phases without enforcing spike semantics" do
    :ok = put_tool_governance_config()

    projection = Wardwright.PolicyProjection.projection("tool-governance")
    [simulation] = Wardwright.PolicyProjection.simulations("tool-governance")

    assert projection["engine"]["engine_id"] == "tool-context-plan"

    assert projection["engine"]["capabilities"]["phases"] == [
             "tool.planning",
             "tool.result_interpreting",
             "tool.loop_governing",
             "receipt.finalized"
           ]

    nodes = projection["phases"] |> Enum.flat_map(& &1["nodes"])

    assert Enum.any?(nodes, fn node ->
             node["id"] == "tool-policy.github-write-tools" and
               node["reads"] == [
                 "request.tools",
                 "request.tool_choice",
                 "message.tool_calls",
                 "decision.tool_context"
               ] and
               node["writes"] == ["tool.allowed", "policy.actions"]
           end)

    assert Enum.any?(nodes, fn node ->
             node["id"] == "tool-policy.repeat-github-tool" and
               node["reads"] == ["decision.tool_context", "policy_cache.session.tool_call"] and
               node["writes"] == ["decision.blocked", "final.status"]
           end)

    assert Enum.any?(nodes, &(&1["id"] == "tool.receipt-context"))
    assert [%{"class" => "ordered", "node_ids" => node_ids}] = projection["conflicts"]
    assert "tool-policy.github-write-tools" in node_ids
    assert "tool-policy.shell-write-tools" in node_ids

    assert simulation["scenario_id"] == "configured-tool-policy"
    assert simulation["verdict"] == "passed"

    assert get_in(simulation, ["receipt_preview", "decision", "tool_context", "primary_tool"]) ==
             %{
               "namespace" => "mcp.github",
               "name" => "create_pull_request",
               "risk_class" => "write",
               "source" => "declared_tool"
             }
  end

  test "LiveView projection workbench renders selected pattern and mode" do
    :ok = put_route_gate_config()
    {:ok, view, html} = live(build_conn(), "/policies/route-privacy/trace_overlay")

    assert html =~ "Private context route gate"
    assert html =~ "Trace overlay"
    assert html =~ "Request route plan"
    assert html =~ "Artifact first"
    assert html =~ "Policy nodes"
    assert html =~ "Simulation evidence"
    assert html =~ "Review load"

    connected_html = render(view)

    assert connected_html =~ "Private context route gate"
    assert connected_html =~ "Trace overlay"
    assert connected_html =~ "Request route plan"
    assert connected_html =~ "Artifact first"
    assert connected_html =~ "Policy nodes"
    assert connected_html =~ "Simulation evidence"
    assert connected_html =~ "State model"
    assert connected_html =~ "Review load"

    assert {:error, {:redirect, %{to: "/policies/route-privacy/effect_matrix"}}} =
             view
             |> element("a", "Effect matrix")
             |> render_click()

    {:ok, matrix_view, _html} = live(build_conn(), "/policies/route-privacy/effect_matrix")

    matrix_html = render(matrix_view)

    assert matrix_html =~ "Private context route gate"
    assert matrix_html =~ "Effect matrix"
    assert matrix_html =~ "route.allowed_targets"
  end

  test "LiveView state-machine mode shows default and explicit state projections" do
    :ok = put_route_gate_config()
    {:ok, route_view, route_html} = live(build_conn(), "/policies/route-privacy/state_machine")

    assert route_html =~ "State machine"
    assert route_html =~ "default one-state"
    assert route_html =~ "No explicit transitions"
    assert route_html =~ "Assistant boundary"
    assert route_html =~ "explain_projection"
    assert render(route_view) =~ "request-policy.private-route-gate"

    {:ok, retry_view, retry_html} = live(build_conn(), "/policies/tts-retry/state_machine")

    assert retry_html =~ "explicit stateful"
    assert retry_html =~ "Observing"
    assert retry_html =~ "Retrying"
    assert render(retry_view) =~ "stream.match"
  end

  defp put_route_gate_config do
    config =
      Wardwright.default_config()
      |> Map.put("governance", [
        %{
          "id" => "private-route-gate",
          "kind" => "route_gate",
          "action" => "restrict_routes",
          "contains" => "private-data-risk",
          "message" => "private context must stay local",
          "allowed_targets" => [Wardwright.local_model()]
        },
        %{
          "id" => "fallback-route-gate",
          "kind" => "route_gate",
          "action" => "switch_model",
          "contains" => "force-managed",
          "message" => "operator selected managed fallback",
          "target_model" => Wardwright.managed_model()
        }
      ])

    assert {:ok, _config} = Wardwright.put_config(config)
    :ok
  end

  defp put_tool_governance_config do
    config =
      Wardwright.default_config()
      |> Map.put("governance", [
        %{
          "id" => "github-write-tools",
          "kind" => "tool_selector",
          "namespace" => "mcp.github",
          "name" => "create_pull_request",
          "risk_class" => "write",
          "action" => "constrain_tools"
        },
        %{
          "id" => "shell-write-tools",
          "kind" => "tool_denylist",
          "namespace" => "shell",
          "risk_class" => "irreversible",
          "action" => "deny_tool"
        },
        %{
          "id" => "repeat-github-tool",
          "kind" => "tool_loop_threshold",
          "namespace" => "mcp.github",
          "name" => "create_pull_request",
          "threshold" => 3,
          "action" => "fail_closed"
        }
      ])

    assert {:ok, _config} = Wardwright.put_config(config)
    :ok
  end

  test "LiveView workbench updates from runtime PubSub visibility events" do
    {:ok, view, html} = live(build_conn(), "/policies/route-privacy/phase_map")

    assert html =~ "Runtime Visibility"
    assert html =~ "History Cache"
    refute html =~ "route.selected"

    assert {:ok, %{"type" => "route.selected"}} =
             Wardwright.Runtime.record_session_event(
               "coding-balanced",
               "2026-05-13.mock",
               "liveview-session",
               "route.selected",
               %{"selected_model" => "mock/liveview"}
             )

    updated = render(view)

    assert updated =~ "route.selected"
    assert updated =~ "liveview-session"
    assert updated =~ "mock/liveview"
  end

  test "LiveView workbench shows bounded policy cache writes as live history" do
    Wardwright.PolicyCache.configure(%{"max_entries" => 4, "recent_limit" => 4})

    {:ok, view, html} = live(build_conn(), "/policies/route-privacy/phase_map")

    assert html =~ "History Cache"
    assert html =~ "0/4"
    refute html =~ "tool_call"

    assert {:ok, _event} =
             Wardwright.PolicyCache.add(%{
               "kind" => "tool_call",
               "key" => "shell:ls",
               "scope" => %{"session_id" => "live-history-session"},
               "created_at_unix_ms" => 1
             })

    updated = render(view)

    assert updated =~ "1/4"
    assert updated =~ "tool_call"
    assert updated =~ "shell:ls"
    assert updated =~ "live-history-session"
  end

  test "LiveView history cache does not render raw cached text by default" do
    Wardwright.PolicyCache.configure(%{"max_entries" => 4, "recent_limit" => 4})

    {:ok, view, _html} = live(build_conn(), "/policies/route-privacy/phase_map")

    assert {:ok, _event} =
             Wardwright.PolicyCache.add(%{
               "kind" => "request_text",
               "key" => "chat_completion",
               "value" => %{"text" => "do not show this private prompt"},
               "created_at_unix_ms" => 1
             })

    updated = render(view)

    assert updated =~ "request_text"
    assert updated =~ "chat_completion"
    assert updated =~ "global scope"
    refute updated =~ "do not show this private prompt"
  end
end
