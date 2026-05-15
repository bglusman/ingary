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
  end

  test "route projection graph exposes policy overlay and assistant governance contract" do
    projection = Wardwright.PolicyProjection.projection("route-privacy")

    graph = projection["route_graph_overlay"]

    assert graph["root"] == "dispatcher.prompt_length"
    assert graph["receipt_fields"] == ["policy_route_constraints", "route_blocked"]
    assert graph["policy_overlay"]["constraint"] == "restrict_routes"

    assert Enum.any?(graph["nodes"], fn node ->
             node["label"] == Wardwright.managed_model() and
               node["policy_state"] == "constrained" and
               node["policy_note"] =~ "restrict_routes"
           end)

    assert Enum.any?(projection["model_policy_differences"], fn row ->
             row["model"] == Wardwright.managed_model() and row["policy_overlay"] =~ "removed"
           end)

    assert %{"source_of_truth" => "deterministic_policy_artifact", "tools" => tools} =
             projection["assistant_contract"]

    assert MapSet.new(Enum.map(tools, & &1["name"])) ==
             MapSet.new([
               "explain_projection",
               "simulate_policy",
               "propose_rule_change",
               "inspect_receipt",
               "inspect_route_plan",
               "validate_policy_artifact"
             ])

    assert [
             %{
               "kind" => "agent_escalation",
               "activation" => "simulation_invocation_only",
               "distinct_from_deterministic_actions" => true
             }
           ] = projection["governance_actions"]
  end

  test "route projection graph is derived from the supplied config" do
    config =
      Wardwright.default_config()
      |> Map.put("route_root", "cascade.private-first")
      |> Map.put("cascades", [
        %{"id" => "cascade.private-first", "models" => [Wardwright.local_model()]}
      ])

    graph = Wardwright.PolicyProjection.projection("route-privacy", config)["route_graph_overlay"]

    assert graph["root"] == "cascade.private-first"

    assert Enum.any?(graph["nodes"], fn node ->
             node["id"] == "cascade.private-first" and node["type"] == "cascade"
           end)
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

  test "LiveView projection workbench renders selected pattern and mode" do
    {:ok, view, html} = live(build_conn(), "/policies/route-privacy/trace_overlay")

    assert html =~ "Private context route gate"
    assert html =~ "Trace overlay"
    assert html =~ "Starlark route gate"

    connected_html = render(view)

    assert connected_html =~ "Private context route gate"
    assert connected_html =~ "Trace overlay"
    assert connected_html =~ "Starlark route gate"

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

  test "LiveView route graph renders graph, assistant, and governance panels" do
    {:ok, _view, html} = live(build_conn(), "/policies/route-privacy/route_graph")

    assert html =~ "Route graph"
    assert html =~ "data-route-graph="
    assert html =~ "Model Policy Differences"
    assert html =~ "AI Policy Assistant"
    assert html =~ "inspect_route_plan"
    assert html =~ "validate_policy_artifact"
    assert html =~ "Governance Escalation"
    assert html =~ "simulation_invocation_only"
    assert html =~ "policy_route_constraints"
    assert html =~ "route_blocked"
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
