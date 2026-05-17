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
    original_workspace = Application.get_env(:wardwright, :policy_recipe_workspace_dir)

    workspace_dir =
      Path.join(System.tmp_dir!(), "wardwright-live-default-#{System.unique_integer()}")

    Application.put_env(:wardwright, :policy_recipe_workspace_dir, workspace_dir)

    on_exit(fn ->
      case original_workspace do
        nil -> Application.delete_env(:wardwright, :policy_recipe_workspace_dir)
        value -> Application.put_env(:wardwright, :policy_recipe_workspace_dir, value)
      end
    end)

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
    assert Enum.all?(nodes, &is_binary(get_in(&1, ["annotations", "why"])))
    assert Enum.all?(nodes, &is_binary(get_in(&1, ["annotations", "change_when"])))
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
    assert html =~ "Trace details"
    assert html =~ "raw run evidence"
    assert html =~ "Request route plan"
    assert html =~ "Artifact first"
    assert html =~ "Policy nodes"
    assert html =~ "Simulation evidence"
    assert html =~ "Review load"
    assert html =~ "Why this exists"

    connected_html = render(view)

    assert connected_html =~ "Private context route gate"
    assert connected_html =~ "Trace details"
    assert connected_html =~ "Request route plan"
    assert connected_html =~ "Artifact first"
    assert connected_html =~ "Policy nodes"
    assert connected_html =~ "Simulation evidence"
    assert connected_html =~ "State model"
    assert connected_html =~ "Review load"
    assert connected_html =~ "Why this exists"

    assert {:error, {:redirect, %{to: "/policies/route-privacy/effect_matrix"}}} =
             view
             |> element("a", "Effect table")
             |> render_click()

    {:ok, matrix_view, _html} = live(build_conn(), "/policies/route-privacy/effect_matrix")

    matrix_html = render(matrix_view)

    assert matrix_html =~ "Private context route gate"
    assert matrix_html =~ "Effect table"
    assert matrix_html =~ "writes and actions"
    assert matrix_html =~ "route.allowed_targets"
  end

  test "browser layout loads the LiveView client runtime" do
    conn = get(build_conn(), "/policies/route-privacy/diagram")
    html = html_response(conn, 200)

    assert html =~ ~s(<meta name="csrf-token")
    assert html =~ ~s(src="/vendor/phoenix/phoenix.min.js")
    assert html =~ ~s(src="/vendor/phoenix_live_view/phoenix_live_view.min.js")
    assert html =~ ~s(src="/assets/wardwright_live.js")
  end

  test "LiveView client assets are served without an npm build step" do
    conn = get(build_conn(), "/assets/wardwright_live.js")
    assert response(conn, 200) =~ "new window.LiveView.LiveSocket"

    conn = get(build_conn(), "/vendor/phoenix/phoenix.min.js")
    assert response(conn, 200) =~ "var Phoenix"

    conn = get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.min.js")
    assert response(conn, 200) =~ "var LiveView"
  end

  test "LiveView diagram mode renders projection graph from backend facts" do
    {:ok, view, html} = live(build_conn(), "/policies/tts-retry/diagram")

    assert html =~ "Time-travel stream retry"
    assert html =~ "Advanced projection details"
    assert html =~ "Use your agent"
    assert html =~ "/mcp"
    assert html =~ "wardwright tools"
    assert html =~ "Policy Simulator"
    assert html =~ "Policy run map"
    assert html =~ "State and model"
    assert html =~ "Playback"
    assert html =~ "Ready: 5 trace events available for playback."
    assert html =~ "waiting at input boundary"
    assert html =~ "Policy projection graph"
    assert html =~ "possible route for this input"
    assert html =~ "already played"
    assert html =~ "conflict"
    assert html =~ "no-old-client"
    assert html =~ "retry arbiter"
    assert html =~ "abort_attempt"
    assert html =~ "retry_with_reminder"
    assert html =~ "Attempt loop"
    assert html =~ "Attempt 1"
    assert html =~ "withheld_and_aborted"
    assert html =~ "Attempt 2"
    assert html =~ "released_after_retry"
    assert html =~ "Use the current client adapter in the migration note."
    refute html =~ "No output is released to the user in this simulated branch"

    connected_html = render(view)

    assert connected_html =~ "regex matched"
    assert connected_html =~ "retry selected"
    assert connected_html =~ "retry stream released"
    assert connected_html =~ "receipt preview"
  end

  test "LiveView diagram simulation can step through matching rules and state changes" do
    {:ok, view, html} = live(build_conn(), "/policies/tts-retry/diagram")

    assert html =~ "Ready: 5 trace events available for playback."
    assert html =~ "waiting at input boundary"
    assert html =~ "pending"

    stepped =
      view
      |> element("button", "Step")
      |> render_click()

    assert stepped =~ "Step 1 of 5: state observing, response.streaming."
    assert stepped =~ "chunk held"
    assert stepped =~ "active"

    stepped =
      view
      |> element("button", "Step")
      |> render_click()

    assert stepped =~ "Step 2 of 5: state guarding, response.streaming."
    assert stepped =~ "regex matched"
    assert stepped =~ "completed"

    stepped =
      view
      |> element("button", "Step")
      |> render_click()

    assert stepped =~ "Step 3 of 5: state retrying, response.streaming."
    assert stepped =~ "retry selected"

    stepped =
      view
      |> element("button", "Step")
      |> render_click()

    assert stepped =~ "Step 4 of 5: state retrying, response.streaming."
    assert stepped =~ "retry stream released"

    stepped_back =
      view
      |> element("button", "Back")
      |> render_click()

    assert stepped_back =~ "Step 3 of 5: state retrying, response.streaming."
    assert stepped_back =~ "retry selected"

    reset =
      view
      |> element("button", "Reset")
      |> render_click()

    assert reset =~ "Ready: 5 trace events available for playback."
    assert reset =~ "waiting at input boundary"
  end

  test "LiveView diagram simulation can open directly to a reviewed playback step" do
    {:ok, _view, html} = live(build_conn(), "/policies/tts-retry/diagram/step/2")

    assert html =~ "Step 2 of 5: state guarding, response.streaming."
    assert html =~ "regex matched"
    assert html =~ "Client( completes the prohibited span"
    assert html =~ "completed"
    assert html =~ "active"
  end

  test "LiveView diagram simulation controls restart cleanly from the final step" do
    {:ok, view, html} = live(build_conn(), "/policies/tts-retry/diagram/step/5")

    assert html =~ "Step 5 of 5: state recording, receipt.finalized."

    restarted =
      view
      |> element("button", "Step")
      |> render_click()

    assert restarted =~ "Ready: 5 trace events available for playback."
    assert restarted =~ "waiting at input boundary"

    playing =
      view
      |> element("button", "Play")
      |> render_click()

    assert playing =~ "Pause"
  end

  test "LiveView diagram ignores stale playback timer messages" do
    {:ok, view, _html} = live(build_conn(), "/policies/tts-retry/diagram")

    playing =
      view
      |> element("button", "Play")
      |> render_click()

    assert playing =~ "Ready: 5 trace events available for playback."
    assert playing =~ "Pause"

    send(view.pid, {:advance_simulation, make_ref()})
    Process.sleep(20)

    unchanged = render(view)

    assert unchanged =~ "Ready: 5 trace events available for playback."
    assert unchanged =~ "Pause"
    refute unchanged =~ "Step 1 of 5"
  end

  test "LiveView diagram can demonstrate related regex rewrite and state transition" do
    {:ok, _view, html} = live(build_conn(), "/policies/stream-rewrite-state/diagram/step/3")

    assert html =~ "Regex rewrite and state transition"
    assert html =~ "Example set"
    assert html =~ "Workspace examples"
    assert html =~ "wardwright.dev/recipes"
    assert html =~ "account redactor"
    assert html =~ "secret transition"
    assert html =~ "rewrite arbiter"
    assert html =~ "Step 3 of 5: state review_required, response.streaming."
    assert html =~ "related secret matched"
    assert html =~ "state_transition"
    assert html =~ "hold_for_review"
  end

  test "LiveView diagram recomputes policy path from editable user and model turn" do
    {:ok, view, html} = live(build_conn(), "/policies/stream-rewrite-state/diagram")

    assert html =~ "Editable turn"
    assert html =~ "Raw user input"
    assert html =~ "Raw model output / stream"
    assert html =~ "User-visible output"
    refute html =~ "Model receives after Wardwright"
    assert html =~ "Relevant examples"
    assert html =~ "Cross-policy probes"
    assert html =~ "review_required"
    assert html =~ "No output is released to the user in this simulated branch"

    changed =
      view
      |> element("form.turn_editor_grid")
      |> render_change(%{
        "simulation" => %{
          "user_input" => "Write a neutral update.",
          "model_response" => "ordinary response text with no matching tokens"
        }
      })

    assert changed =~ "Edited stream has no regex match"
    assert changed =~ "stream released"
    assert changed =~ "Ready: 3 trace events available for playback."
    assert changed =~ "ordinary response text with no matching tokens"
    assert changed =~ "Released unchanged. The user receives this raw model output."
    refute changed =~ "User receives after Wardwright"
    refute changed =~ "review hold selected"
  end

  test "LiveView diagram releases unchanged output when edited text no longer matches rewrite rules" do
    {:ok, view, _html} = live(build_conn(), "/policies/stream-rewrite-state/diagram")

    selected =
      view
      |> element("form[phx-change='select-simulation-input']")
      |> render_change(%{"simulation_input" => "rewrite-then-secret"})

    assert selected =~ "No output is released to the user in this simulated branch"

    changed =
      view
      |> element("form.turn_editor_grid")
      |> render_change(%{
        "simulation" => %{
          "user_input" => "Summarize the billing incident without exposing credentials.",
          "model_response" =>
            "account {redacted} appears in the answer\n{redacted} follows in the held horizon",
          "history_context" => %{
            "recent_related_secret_matches" => "0",
            "policy_state" => "observing"
          }
        }
      })

    assert changed =~ "Edited stream has no regex match"
    assert changed =~ "stream released"
    assert changed =~ "Released unchanged. The user receives this raw model output."
    assert changed =~ "account {redacted} appears in the answer"
    refute changed =~ "No output is released to the user in this simulated branch"
    refute changed =~ "User-visible output"
  end

  test "LiveView diagram shows before and after boundaries only when policy rewrites them" do
    {:ok, view, html} = live(build_conn(), "/policies/stream-rewrite-state/diagram")

    assert html =~ "Stream: input and output rewrite"
    assert html =~ "Load scenario"
    refute html =~ "Model receives after Wardwright"

    selected =
      view
      |> element("form[phx-change='select-simulation-input']")
      |> render_change(%{"simulation_input" => "input-and-output-rewrite"})

    assert selected =~ "Raw user input"
    assert selected =~ "Model receives after Wardwright"
    assert selected =~ "[private-context omitted]"
    assert selected =~ "Raw model output / stream"
    assert selected =~ "User receives after Wardwright"
    assert selected =~ "account [account-id]"
    assert selected =~ "request context redacted"
    assert selected =~ "alex@example.test"

    submitted =
      view
      |> element("form[phx-submit='select-simulation-input']")
      |> render_submit(%{"simulation_input" => "no-match"})

    assert submitted =~ "Edited stream has no regex match"
    assert submitted =~ "Released unchanged. The user receives this raw model output."
    refute submitted =~ "User receives after Wardwright"
  end

  test "LiveView simulation lets authors edit referenced history that changes behavior" do
    {:ok, view, _html} = live(build_conn(), "/policies/stream-rewrite-state/diagram")

    selected =
      view
      |> element("form[phx-change='select-simulation-input']")
      |> render_change(%{"simulation_input" => "rewrite-only"})

    assert selected =~ "Policy memory used by this run"
    assert selected =~ "Prior related secret matches"
    assert selected =~ "rewritten stream released"
    refute selected =~ "prior related matches read"

    threshold =
      view
      |> element("form[phx-submit='select-simulation-input']")
      |> render_submit(%{"simulation_input" => "history-threshold-escalation"})

    assert threshold =~ "Stream: history threshold escalates"
    assert threshold =~ "Relevant examples"
    assert threshold =~ "History window size"
    assert threshold =~ "3 related secret match"
    assert threshold =~ "review hold selected"

    changed =
      view
      |> element("form.turn_editor_grid")
      |> render_change(%{
        "simulation" => %{
          "user_input" => "Summarize the billing incident without exposing credentials.",
          "model_response" => "account acct_4938 appears in the answer with no new token.",
          "history_context" => %{
            "recent_related_secret_matches" => "3",
            "recent_secret_window_requests" => "5",
            "policy_state" => "observing"
          }
        }
      })

    assert changed =~ "prior related matches read"
    assert changed =~ "3 related secret match"
    assert changed =~ "review hold selected"
    assert changed =~ "No output is released to the user in this simulated branch"
  end

  test "LiveView simulation shows state transitions that affect the next turn model" do
    {:ok, view, _html} = live(build_conn(), "/policies/stream-rewrite-state/diagram")

    selected =
      view
      |> element("form[phx-change='select-simulation-input']")
      |> render_change(%{"simulation_input" => "next-turn-review-model"})

    assert selected =~ "Stream: next turn uses review model"
    assert selected =~ "State and model"
    assert selected =~ "Model: managed/kimi-k2.6"
    assert selected =~ "After this run: review_required uses managed/kimi-k2.6."
    assert selected =~ "history threshold matched"
    assert selected =~ "current stream released"
    assert selected =~ "state change affects subsequent turns"
    assert selected =~ "Released unchanged. The user receives this raw model output."
    refute selected =~ "No output is released to the user in this simulated branch"
  end

  test "LiveView diagram keeps cross-policy scenarios selectable for every policy" do
    {:ok, view, html} = live(build_conn(), "/policies/ambiguous-success/diagram")

    assert html =~ "Artifact: claim without artifact"
    assert html =~ "TTSR: split prohibited span"

    changed =
      view
      |> element("form[phx-change='select-simulation-input']")
      |> render_change(%{"simulation_input" => "split-old-client"})

    assert changed =~ "TTSR: split prohibited span"
    assert changed =~ "Edited input clears missing artifact alert"
    assert changed =~ "no alert"
  end

  test "LiveView recipe source can point at workspace catalogs without changing projection contract" do
    original_workspace = Application.get_env(:wardwright, :policy_recipe_workspace_dir)

    workspace_dir =
      Path.join(System.tmp_dir!(), "wardwright-live-recipes-#{System.unique_integer()}")

    File.mkdir_p!(workspace_dir)

    File.write!(
      Path.join(workspace_dir, "tool-demo.json"),
      Jason.encode!(%{
        "id" => "tool-demo",
        "title" => "Workspace tool policy",
        "category" => "tool.using",
        "promise" => "Review a locally curated tool policy recipe.",
        "pattern_id" => "tool-governance"
      })
    )

    File.write!(
      Path.join(workspace_dir, "unsupported-demo.json"),
      Jason.encode!(%{
        "id" => "unsupported-demo",
        "title" => "Unsupported future policy",
        "category" => "policy.future",
        "promise" => "Exercise a recipe that this build cannot project yet.",
        "pattern_id" => "future-policy-engine"
      })
    )

    Application.put_env(:wardwright, :policy_recipe_workspace_dir, workspace_dir)

    on_exit(fn ->
      case original_workspace do
        nil -> Application.delete_env(:wardwright, :policy_recipe_workspace_dir)
        value -> Application.put_env(:wardwright, :policy_recipe_workspace_dir, value)
      end
    end)

    {:ok, view, html} = live(build_conn(), "/policies/tool-governance/diagram?source=workspace")

    assert html =~ "Workspace examples"
    assert html =~ workspace_dir
    assert html =~ "Workspace tool policy"
    assert html =~ "1 examples reference unsupported policy patterns for this build."
    refute html =~ "Unsupported future policy"
    assert html =~ "Load examples"
    assert html =~ "Tool call governance"
    assert html =~ "tool receipt context"

    workspace =
      view
      |> element("form[phx-submit='select-recipe-source']")
      |> render_submit(%{"recipe_source" => "built_in"})

    assert workspace =~ "Workspace examples"
    assert workspace =~ workspace_dir
    assert workspace =~ "Workspace tool policy"

    {:ok, view, _html} = live(build_conn(), "/policies/tool-governance/diagram?source=workspace")

    assert {:error, {:redirect, %{to: "/policies/tool-governance/state_machine"}}} =
             view
             |> element("a", "State model")
             |> render_click()

    {:ok, _state_view, updated} =
      live(build_conn(), "/policies/tool-governance/state_machine")

    assert updated =~ "Workspace examples"
    assert updated =~ "State model"
  end

  test "LiveView default workspace source loads committed starter recipes" do
    original_workspace = Application.get_env(:wardwright, :policy_recipe_workspace_dir)

    workspace_dir =
      Path.join(System.tmp_dir!(), "wardwright-live-starter-recipes-#{System.unique_integer()}")

    Application.put_env(:wardwright, :policy_recipe_workspace_dir, workspace_dir)

    on_exit(fn ->
      case original_workspace do
        nil -> Application.delete_env(:wardwright, :policy_recipe_workspace_dir)
        value -> Application.put_env(:wardwright, :policy_recipe_workspace_dir, value)
      end
    end)

    {:ok, _view, html} = live(build_conn(), "/policies/route-privacy/diagram")

    assert html =~ "Workspace examples"
    assert html =~ workspace_dir
    assert html =~ "Local private route gate"
    assert html =~ "Local tool loop watch"
    assert html =~ "Private context route gate"
  end

  test "LiveView diagram mode reflects configured route and tool policies" do
    :ok = put_route_gate_config()
    {:ok, _route_view, route_html} = live(build_conn(), "/policies/route-privacy/diagram")

    assert route_html =~ "Private context route gate"
    assert route_html =~ "private-route-gate"
    assert route_html =~ "fallback-route-gate"
    assert route_html =~ "restrict_routes"
    assert route_html =~ "switch_model"
    assert route_html =~ "route"
    assert route_html =~ "Multiple"
    assert route_html =~ "policy"

    :ok = put_tool_governance_config()
    {:ok, _tool_view, tool_html} = live(build_conn(), "/policies/tool-governance/diagram")

    assert tool_html =~ "Tool call governance"
    assert tool_html =~ "github-write-tools"
    assert tool_html =~ "shell-write-tools"
    assert tool_html =~ "repeat-github-tool"
    assert tool_html =~ "constrain_tools"
    assert tool_html =~ "deny_tool"
    assert tool_html =~ "fail_closed"
    assert tool_html =~ "tool receipt context"
  end

  test "LiveView state-machine mode shows default and explicit state projections" do
    :ok = put_route_gate_config()
    {:ok, route_view, route_html} = live(build_conn(), "/policies/route-privacy/state_machine")

    assert route_html =~ "State model"
    assert route_html =~ "State machine transition graph"
    assert route_html =~ "default one-state"
    assert route_html =~ "No explicit transitions"
    assert route_html =~ "Assistant boundary"
    assert route_html =~ "explain_projection"
    assert render(route_view) =~ "request-policy.private-route-gate"

    {:ok, retry_view, retry_html} = live(build_conn(), "/policies/tts-retry/state_machine")

    assert retry_html =~ "explicit stateful"
    assert retry_html =~ "State machine transition graph"
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
