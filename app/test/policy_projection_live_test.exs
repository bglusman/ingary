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
    Wardwright.PolicyCache.reset()
    :ok
  end

  test "policy projection exposes stable review fields and confidence classes" do
    projection = Wardwright.PolicyProjection.projection("route-privacy")

    assert projection["projection_schema"] == "wardwright.policy_projection.v1"
    assert projection["engine"]["language"] == "starlark"
    assert projection["artifact"]["artifact_hash"] =~ "sha256:"

    nodes = projection["phases"] |> Enum.flat_map(& &1["nodes"])
    assert Enum.any?(nodes, &(&1["confidence"] == "opaque"))
    assert Enum.any?(nodes, &(&1["source_span"]["file"] == "policy.star"))
    assert [%{"class" => "ordered"}] = projection["conflicts"]

    workbench = projection["route_workbench"]
    assert workbench["route_root"] == "dispatcher.prompt_length"

    assert Enum.any?(
             workbench["baseline_candidates"],
             &(&1["selected_model"] == Wardwright.local_model())
           )

    assert Enum.any?(workbench["policy_constraints"], &(&1["action"] == "restrict_routes"))
    assert Enum.any?(workbench["policy_constraints"], &(&1["action"] == "switch_model"))
    assert Enum.any?(workbench["policy_constraints"], &(&1["action"] == "reroute"))
    assert Enum.any?(workbench["policy_constraints"], &(&1["receipt_field"] == "route_blocked"))
    assert Enum.any?(workbench["policy_outcomes"], &(&1["route_blocked"] == true))

    assistant = projection["assistant_contract"]
    assert assistant["source_of_truth"] =~ "deterministic policy artifact"

    assert Enum.map(assistant["tool_calls"], & &1["name"]) == [
             "explain_projection",
             "simulate_policy",
             "propose_rule_change",
             "inspect_receipt",
             "inspect_route_plan",
             "validate_policy_artifact"
           ]

    escalation = projection["governance_escalation"]
    assert Enum.any?(escalation["steps"], &(&1["kind"] == "agent_invocation_mock"))
  end

  test "simulation traces link execution evidence back to projection nodes" do
    projection = Wardwright.PolicyProjection.projection("tts-retry")
    node_ids = projection["phases"] |> Enum.flat_map(& &1["nodes"]) |> MapSet.new(& &1["id"])

    [simulation | _] = Wardwright.PolicyProjection.simulations("tts-retry")

    assert simulation["artifact_hash"] == projection["artifact"]["artifact_hash"]
    assert simulation["verdict"] in ["passed", "failed", "inconclusive"]
    assert Enum.any?(simulation["trace"], &MapSet.member?(node_ids, &1["node_id"]))
    assert is_map(simulation["receipt_preview"])
  end

  test "route workbench projection honors the supplied model config" do
    config =
      Wardwright.default_config()
      |> Map.put("targets", [
        %{"model" => "edge/small", "context_window" => 16_000},
        %{"model" => "cloud/large", "context_window" => 200_000}
      ])
      |> Map.put("route_root", "dispatcher.custom")
      |> Map.put("dispatchers", [
        %{"id" => "dispatcher.custom", "models" => ["edge/small", "cloud/large"]}
      ])

    projection = Wardwright.PolicyProjection.projection("route-privacy", config)
    workbench = projection["route_workbench"]

    assert workbench["route_root"] == "dispatcher.custom"
    assert Enum.any?(workbench["nodes"], &(&1["upstream_model_id"] == "edge/small"))
    assert Enum.any?(workbench["nodes"], &(&1["upstream_model_id"] == "cloud/large"))

    assert Enum.any?(
             workbench["policy_constraints"],
             &(&1["constraint"] == "allowed_targets = [\"edge\"]")
           )

    assert Enum.any?(
             workbench["policy_constraints"],
             &(&1["constraint"] == "forced_model = \"cloud/large\"")
           )

    assert Enum.any?(workbench["model_differences"], &(&1["model"] == "edge/small"))
    assert Enum.any?(workbench["model_differences"], &(&1["model"] == "cloud/large"))
  end

  test "LiveView projection workbench renders selected pattern and mode" do
    {:ok, view, html} = live(build_conn(), "/policies/route-privacy/trace_overlay")

    assert html =~ "Private context route gate"
    assert html =~ "Trace overlay"
    assert html =~ "Starlark route gate"
    assert html =~ "Route Graph And Policy Overlay"
    assert html =~ "policy_route_constraints.allowed_targets"
    assert html =~ "AI Policy Assistant"
    assert html =~ "validate_policy_artifact"
    assert html =~ "Governance Escalation Roadmap"
    assert html =~ "agent_invocation_mock"

    connected_html = render(view)

    assert connected_html =~ "Private context route gate"
    assert connected_html =~ "Trace overlay"
    assert connected_html =~ "Starlark route gate"
    assert connected_html =~ "restrict_routes"
    assert connected_html =~ "switch_model"
    assert connected_html =~ "reroute"
    assert connected_html =~ "route_blocked"

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

  test "LiveView workbench updates from runtime PubSub visibility events" do
    {:ok, view, html} = live(build_conn(), "/policies/route-privacy/phase_map")

    assert html =~ "Runtime Visibility"
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
end
