defmodule WardwrightWeb.PolicyProjectionLive do
  @moduledoc false

  use Phoenix.LiveView

  @modes ["phase_map", "effect_matrix", "trace_overlay"]

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Wardwright.Runtime.Events.subscribe(Wardwright.Runtime.Events.topic(:models))
      Wardwright.Runtime.Events.subscribe(Wardwright.Runtime.Events.topic(:receipts))
      Wardwright.Runtime.Events.subscribe(Wardwright.Runtime.Events.topic(:policies))
    end

    {:ok, assign_projection(socket, params)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign_projection(socket, params)}
  end

  defp assign_projection(socket, params) do
    pattern_id = normalize_pattern(Map.get(params, "pattern"))
    mode = normalize_mode(Map.get(params, "mode"))
    projection = Wardwright.PolicyProjection.projection(pattern_id)
    simulations = Wardwright.PolicyProjection.simulations(pattern_id)
    selected_node = first_node(projection)

    socket
    |> assign(:page_title, "Policy Workbench")
    |> assign(:modes, @modes)
    |> assign(:patterns, Wardwright.PolicyProjection.patterns())
    |> assign(:selected_pattern, Wardwright.PolicyProjection.pattern(pattern_id))
    |> assign(:selected_pattern_id, pattern_id)
    |> assign(:mode, mode)
    |> assign(:projection, projection)
    |> assign(:simulations, simulations)
    |> assign(:projection_stats, projection_stats(projection, simulations))
    |> assign(:selected_simulation, List.first(simulations))
    |> assign(:selected_node, selected_node)
    |> assign_new(:runtime_status, fn -> Wardwright.Runtime.status() end)
    |> assign_new(:runtime_events, fn -> [] end)
    |> assign_new(:policy_cache_status, fn -> Wardwright.PolicyCache.status() end)
    |> assign_new(:policy_cache_events, fn -> Wardwright.PolicyCache.recent(%{}, 8) end)
  end

  @impl true
  def handle_info({:wardwright_runtime_event, topic, event}, socket) do
    event = Map.put(event, "topic", topic)
    events = [event | socket.assigns.runtime_events] |> Enum.take(8)

    {:noreply,
     socket
     |> assign(:runtime_events, events)
     |> assign(:runtime_status, Wardwright.Runtime.status())
     |> assign(:policy_cache_status, Wardwright.PolicyCache.status())
     |> assign(:policy_cache_events, Wardwright.PolicyCache.recent(%{}, 8))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <aside class="sidebar">
      <div class="brand">
        <span class="mark">IG</span>
        <div>
          <strong>Wardwright</strong>
          <span>Policy projection workbench</span>
        </div>
      </div>

      <nav>
        <a
          :for={pattern <- @patterns}
          class={if pattern["id"] == @selected_pattern_id, do: "active", else: ""}
          href={path(pattern["id"], @mode)}
        >
          <strong><%= pattern["title"] %></strong>
          <span><%= pattern["category"] %></span>
        </a>
      </nav>

      <div class="sidebar_footer">
        <span>Engine</span>
        <strong><%= @projection["engine"]["display_name"] %></strong>
        <span>Artifact</span>
        <code><%= @projection["artifact"]["artifact_hash"] %></code>
      </div>
    </aside>

    <section class="workspace">
      <header class="topbar">
        <div>
          <p class="eyebrow">LiveView projection prototype</p>
          <h1><%= @selected_pattern["title"] %></h1>
          <p><%= @selected_pattern["promise"] %></p>
        </div>
        <div class="engine_card">
          <.badge value={@projection["engine"]["language"]} />
          <strong><%= @projection["engine"]["engine_id"] %></strong>
          <span><%= @projection["artifact"]["policy_version"] %></span>
        </div>
      </header>

      <section class="scan_strip" aria-label="Policy authoring summary">
        <article>
          <span>Authority</span>
          <strong>Artifact first</strong>
          <small><%= @projection["artifact"]["policy_version"] %></small>
        </article>
        <article>
          <span>Policy nodes</span>
          <strong><%= @projection_stats.node_count %></strong>
          <small><%= @projection_stats.exact_count %> exact, <%= @projection_stats.opaque_count %> opaque</small>
        </article>
        <article>
          <span>Simulation evidence</span>
          <strong><%= @projection_stats.simulation_count %> runs</strong>
          <small><%= @projection_stats.trace_event_count %> trace events</small>
        </article>
        <article>
          <span>Review load</span>
          <strong><%= @projection_stats.review_count %></strong>
          <small>conflicts, warnings, opaque regions</small>
        </article>
      </section>

      <section class="panel">
        <div class="panel_header">
          <div>
            <h2>Stable Projection Interface</h2>
            <p>
              The deterministic artifact remains the authority. This page renders a projection emitted by the Elixir backend,
              then shows simulation evidence against that projection.
            </p>
          </div>
          <.badge value={@projection["projection_schema"]} class="schema_badge" />
        </div>

        <div class="mode_tabs">
          <a :for={mode <- @modes} class={if mode == @mode, do: "active", else: ""} href={path(@selected_pattern_id, mode)}>
            <%= mode_label(mode) %>
          </a>
        </div>

        <%= if @mode == "effect_matrix" do %>
          <.effect_matrix projection={@projection} />
        <% else %>
          <%= if @mode == "trace_overlay" do %>
            <.trace_overlay projection={@projection} simulation={@selected_simulation} />
          <% else %>
            <.phase_map projection={@projection} />
          <% end %>
        <% end %>
      </section>

      <section class="split">
        <div class="panel">
          <div class="panel_header">
            <div>
              <h2>Runtime Visibility</h2>
              <p>Live PubSub projection of model and session runtime activity.</p>
            </div>
            <.badge value={"#{length(@runtime_status["sessions"])} sessions"} />
          </div>

          <dl class="kv">
            <dt>Models</dt>
            <dd><%= length(@runtime_status["models"]) %></dd>
            <dt>Sessions</dt>
            <dd><%= length(@runtime_status["sessions"]) %></dd>
            <dt>Last Event</dt>
            <dd><%= runtime_event_label(List.first(@runtime_events)) %></dd>
          </dl>

          <div class="timeline compact">
            <article :for={event <- @runtime_events} class="trace_event info">
              <span><%= event["topic"] %></span>
              <strong><%= event["type"] %></strong>
              <.badge value={"seq #{event["sequence"] || "-"}"} />
              <small><%= runtime_event_detail(event) %></small>
            </article>
          </div>
        </div>

        <div class="panel">
          <div class="panel_header">
            <div>
              <h2>Selected Node</h2>
              <p><%= @selected_node["summary"] %></p>
            </div>
            <.badge value={@selected_node["confidence"]} />
          </div>

          <dl class="kv">
            <dt>Phase</dt>
            <dd><%= @selected_node["phase"] %></dd>
            <dt>Kind</dt>
            <dd><%= @selected_node["kind"] %></dd>
            <dt>Reads</dt>
            <dd><%= Enum.join(@selected_node["reads"], ", ") %></dd>
            <dt>Writes</dt>
            <dd><%= Enum.join(@selected_node["writes"], ", ") %></dd>
          </dl>

          <h3>Actions</h3>
          <div class="chips">
            <span :for={action <- @selected_node["actions"]} class="chip"><%= action %></span>
          </div>
        </div>

        <div class="panel">
          <div class="panel_header">
            <div>
              <h2>History Cache</h2>
              <p>Bounded policy facts available to history-aware rules.</p>
            </div>
            <.badge value={"#{@policy_cache_status["entry_count"]}/#{@policy_cache_status["max_entries"]}"} />
          </div>

          <dl class="kv">
            <dt>Store</dt>
            <dd><%= @policy_cache_status["kind"] %></dd>
            <dt>Topology</dt>
            <dd><%= @policy_cache_status["topology"] || "single_table" %></dd>
            <dt>Sessions</dt>
            <dd><%= @policy_cache_status["session_count"] || 0 %></dd>
            <dt>Recent Limit</dt>
            <dd><%= @policy_cache_status["recent_limit"] %></dd>
            <dt>Next Sequence</dt>
            <dd><%= @policy_cache_status["next_sequence"] %></dd>
          </dl>

          <div class="timeline compact">
            <article :for={event <- @policy_cache_events} class="trace_event info">
              <span><%= event["kind"] %></span>
              <strong><%= event["key"] %></strong>
              <.badge value={"seq #{event["sequence"]}"} />
              <small><%= policy_cache_event_detail(event) %></small>
            </article>
          </div>
        </div>

        <div class="panel">
          <div class="panel_header">
            <div>
              <h2>Review Findings</h2>
              <p>Conflicts and opaque regions are backend-owned projection data.</p>
            </div>
          </div>

          <div class="finding_list">
            <div :for={conflict <- @projection["conflicts"]} class="finding">
              <.badge value={conflict["class"]} />
              <span>
                <%= conflict["summary"] %>
                <%= if conflict["required_resolution"], do: " Resolution: #{conflict["required_resolution"]}." %>
              </span>
            </div>
            <div :for={region <- @projection["opaque_regions"]} class="finding">
              <.badge value="opaque" />
              <span><%= region["reason"] %> Review: <%= region["review_requirement"] %></span>
            </div>
            <div :for={warning <- @projection["warnings"]} class="finding">
              <.badge value="warning" />
              <span><%= warning %></span>
            </div>
          </div>
        </div>
      </section>

      <section class="split">
        <div class="panel">
          <div class="panel_header">
            <div>
              <h2>Simulation Trace</h2>
              <p><%= @selected_simulation["title"] %>: <%= @selected_simulation["expected_behavior"] %></p>
            </div>
            <.badge value={@selected_simulation["verdict"]} />
          </div>

          <div class="timeline">
            <article :for={event <- @selected_simulation["trace"]} class={"trace_event #{event["severity"]}"}>
              <span><%= event["phase"] %></span>
              <strong><%= event["label"] %></strong>
              <.badge value={event["kind"]} />
              <small><%= event["detail"] %></small>
            </article>
          </div>
        </div>

        <div class="panel">
          <div class="panel_header">
            <div>
              <h2>Receipt Preview</h2>
              <p>Evidence generated by exercising the compiled policy plan.</p>
            </div>
          </div>
          <pre><%= Jason.encode!(@selected_simulation["receipt_preview"], pretty: true) %></pre>
        </div>
      </section>
    </section>
    """
  end

  attr(:projection, :map, required: true)

  def phase_map(assigns) do
    ~H"""
    <div class="phase_grid">
      <article :for={phase <- @projection["phases"]} class="phase_column">
        <div class="phase_header">
          <strong><%= phase["title"] %></strong>
          <span><%= phase["description"] %></span>
        </div>
        <div class="node_stack">
          <div :for={node <- phase["nodes"]} class={"node_card #{node["confidence"]}"}>
            <div>
              <strong><%= node["label"] %></strong>
              <.badge value={node["confidence"]} />
            </div>
            <span><%= node["summary"] %></span>
            <small><%= node["kind"] %></small>
          </div>
        </div>
      </article>
    </div>
    """
  end

  attr(:projection, :map, required: true)

  def effect_matrix(assigns) do
    ~H"""
    <div class="effect_matrix">
      <div class="effect_row header">
        <span>Node</span>
        <span>Phase</span>
        <span>Effect</span>
        <span>Target</span>
        <span>Confidence</span>
      </div>
      <div :for={effect <- @projection["effects"]} class="effect_row">
        <strong><%= node_label(@projection, effect["node_id"]) %></strong>
        <span><%= effect["phase"] %></span>
        <span><%= effect["effect"] %></span>
        <span><%= effect["target"] %></span>
        <.badge value={effect["confidence"]} />
      </div>
    </div>
    """
  end

  attr(:projection, :map, required: true)
  attr(:simulation, :map, required: true)

  def trace_overlay(assigns) do
    assigns =
      assign(assigns,
        executed_nodes:
          assigns.simulation["trace"]
          |> Enum.map(& &1["node_id"])
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()
      )

    ~H"""
    <div class="trace_overlay">
      <div class="trace_summary">
        <.badge value={@simulation["verdict"]} />
        <strong><%= @simulation["input_summary"] %></strong>
        <span><%= @simulation["expected_behavior"] %></span>
      </div>
      <div class="phase_grid">
        <article :for={phase <- @projection["phases"]} class="phase_column">
          <div class="phase_header">
            <strong><%= phase["title"] %></strong>
            <span><%= phase["description"] %></span>
          </div>
          <div class="node_stack">
            <div
              :for={node <- phase["nodes"]}
              class={"node_card #{if MapSet.member?(@executed_nodes, node["id"]), do: "executed", else: node["confidence"]}"}
            >
              <div>
                <strong><%= node["label"] %></strong>
                <.badge value={if MapSet.member?(@executed_nodes, node["id"]), do: "executed", else: node["confidence"]} />
              </div>
              <span><%= node["summary"] %></span>
            </div>
          </div>
        </article>
      </div>
    </div>
    """
  end

  attr(:value, :string, required: true)
  attr(:class, :string, default: "")

  def badge(assigns) do
    ~H"""
    <span class={"badge #{@class} #{String.replace(@value, ~r/[^a-zA-Z0-9]+/, "-") |> String.downcase()}"}><%= @value %></span>
    """
  end

  def styles do
    """
    :root { color: #17202a; background: #f4f6f8; font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; }
    * { box-sizing: border-box; }
    body { margin: 0; }
    a { color: inherit; text-decoration: none; }
    .shell, .shell > [data-phx-main] { min-height: 100vh; }
    .shell > [data-phx-main] { display: grid; grid-template-columns: 260px minmax(0, 1fr); }
    .sidebar { display: flex; flex-direction: column; gap: 24px; padding: 22px 16px; color: #e6ebef; background: #25313b; }
    .brand { display: flex; align-items: center; gap: 12px; }
    .mark { display: inline-grid; place-items: center; width: 40px; height: 40px; border: 1px solid #657583; border-radius: 6px; background: #33414c; color: #fff; font-weight: 800; }
    .brand div, nav, .sidebar_footer { display: grid; gap: 6px; }
    .brand span, .sidebar_footer span { color: #adbac5; font-size: 12px; }
    nav a { display: grid; gap: 3px; padding: 10px 12px; border: 1px solid transparent; border-radius: 6px; }
    nav a span { color: #adbac5; font-size: 12px; }
    nav a.active, nav a:hover { border-color: #6f7f8e; background: #34424e; }
    .sidebar_footer { margin-top: auto; padding: 14px; border: 1px solid #4d5f6f; border-radius: 6px; background: #2d3944; overflow-wrap: anywhere; }
    .workspace { min-width: 0; padding: 28px; }
    .topbar { display: flex; align-items: flex-start; justify-content: space-between; gap: 18px; margin-bottom: 18px; }
    .topbar > div:first-child, .panel_header > div { min-width: 0; flex: 1 1 auto; }
    .eyebrow { margin: 0 0 4px; color: #5e6b76; font-size: 12px; font-weight: 800; text-transform: uppercase; }
    h1, h2, h3, p { margin-top: 0; }
    h1 { margin-bottom: 6px; font-size: 30px; line-height: 1.12; }
    h2 { margin-bottom: 6px; font-size: 19px; }
    h3 { margin: 18px 0 8px; font-size: 14px; }
    p { color: #5e6b76; line-height: 1.45; }
    .panel { min-width: 0; margin-bottom: 18px; padding: 20px; border: 1px solid #d3dbe2; border-radius: 8px; background: #fff; box-shadow: 0 1px 2px rgb(16 24 40 / 5%); }
    .panel_header { display: flex; align-items: flex-start; justify-content: space-between; gap: 18px; margin-bottom: 16px; }
    .engine_card { display: grid; gap: 6px; min-width: 260px; padding: 12px; border: 1px solid #d3dbe2; border-radius: 8px; background: #fff; }
    .engine_card span:last-child { color: #66727c; font-size: 12px; }
    .scan_strip { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 10px; margin-bottom: 18px; }
    .scan_strip article { display: grid; gap: 4px; min-width: 0; padding: 12px; border: 1px solid #d3dbe2; border-radius: 8px; background: #fff; box-shadow: 0 1px 2px rgb(16 24 40 / 4%); }
    .scan_strip span { color: #66727c; font-size: 12px; font-weight: 800; text-transform: uppercase; }
    .scan_strip strong { color: #17202a; font-size: 18px; line-height: 1.2; }
    .scan_strip small { color: #5e6b76; line-height: 1.35; overflow-wrap: anywhere; }
    .mode_tabs { display: inline-flex; flex-wrap: wrap; gap: 4px; margin-bottom: 14px; padding: 4px; border: 1px solid #d5dde4; border-radius: 8px; background: #f3f6f8; }
    .mode_tabs a { border: 1px solid transparent; border-radius: 6px; padding: 7px 10px; color: #3a4650; font-size: 13px; font-weight: 800; }
    .mode_tabs a.active, .mode_tabs a:hover { border-color: #c5d0d9; background: #fff; }
    .phase_grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px; }
    .phase_column, .node_stack, .timeline, .finding_list, .trace_overlay, .effect_matrix, .chips { display: grid; gap: 9px; }
    .phase_header, .node_card, .finding, .trace_event, .trace_summary, .effect_row { padding: 12px; border: 1px solid #d5dde4; border-radius: 8px; background: #fbfcfd; }
    .phase_header span, .node_card span, .trace_summary span, .finding span, .trace_event small { color: #5e6b76; font-size: 13px; line-height: 1.4; }
    .node_card { display: grid; gap: 8px; min-height: 116px; }
    .node_card div { display: flex; flex-wrap: wrap; align-items: flex-start; justify-content: space-between; gap: 8px; }
    .node_card.executed, .node_card.exact { border-color: #94c7b5; background: #f0faf6; }
    .node_card.inferred, .node_card.declared { border-color: #d9bd72; background: #fffaf0; }
    .node_card.opaque { border-color: #df9a9a; background: #fff5f5; }
    .split { display: grid; grid-template-columns: minmax(0, 1fr) minmax(340px, 0.82fr); gap: 18px; align-items: start; }
    .kv { display: grid; grid-template-columns: max-content minmax(0, 1fr); gap: 8px 14px; }
    .kv dt { color: #66727c; }
    .kv dd { margin: 0; font-weight: 800; overflow-wrap: anywhere; }
    .chips { display: flex; flex-wrap: wrap; }
    .chip { padding: 4px 7px; border: 1px solid #d5dde4; border-radius: 6px; color: #3a4650; background: #fff; font-size: 12px; font-weight: 800; }
    .finding { display: grid; grid-template-columns: max-content minmax(0, 1fr); gap: 10px; align-items: start; }
    .trace_event { display: grid; grid-template-columns: 128px minmax(0, 1fr) max-content; gap: 10px; align-items: center; }
    .trace_event > span { color: #66727c; font-size: 12px; font-weight: 800; text-transform: uppercase; }
    .trace_event small { grid-column: 2 / -1; }
    .trace_event.pass { border-color: #94c7b5; background: #f0faf6; }
    .trace_event.warn { border-color: #d9bd72; background: #fffaf0; }
    .trace_event.block { border-color: #df9a9a; background: #fff5f5; }
    .effect_row { display: grid; grid-template-columns: minmax(140px, 1.1fr) minmax(140px, 1fr) minmax(130px, 1fr) minmax(100px, 0.7fr) max-content; gap: 10px; align-items: center; }
    .effect_row.header { color: #66727c; background: #f3f6f8; font-size: 12px; font-weight: 800; text-transform: uppercase; }
    .trace_summary { display: grid; grid-template-columns: max-content minmax(0, 1fr); gap: 6px 10px; align-items: start; }
    .trace_summary span { grid-column: 2; }
    .badge { display: inline-flex; align-items: center; width: fit-content; max-width: 100%; min-height: 24px; padding: 3px 8px; border: 1px solid #cad4dc; border-radius: 999px; color: #33414c; background: #f5f7f9; font-size: 12px; font-weight: 800; line-height: 1.2; white-space: nowrap; }
    .schema_badge { overflow-wrap: normal; }
    .badge.exact, .badge.executed, .badge.passed, .badge.pass { border-color: #94c7b5; color: #1c654f; background: #edf8f3; }
    .badge.declared, .badge.inferred, .badge.inconclusive, .badge.warning, .badge.warn { border-color: #d9bd72; color: #73570d; background: #fff7df; }
    .badge.opaque, .badge.failed, .badge.block, .badge.conflicting { border-color: #df9a9a; color: #8b2d2d; background: #fff1f1; }
    pre, code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
    pre { max-height: 380px; overflow: auto; padding: 12px; border: 1px solid #dbe2e8; border-radius: 6px; color: #25313b; background: #f7f9fb; font-size: 12px; line-height: 1.45; }
    @media (max-width: 980px) { .shell > [data-phx-main], .split, .scan_strip { grid-template-columns: 1fr; } .sidebar { position: sticky; top: 0; z-index: 1; } .topbar, .panel_header { display: grid; } .effect_row, .trace_event { grid-template-columns: 1fr; } .trace_event small, .trace_summary span { grid-column: 1; } .engine_card { min-width: 0; } .schema_badge { white-space: normal; overflow-wrap: anywhere; } }
    """
  end

  defp projection_stats(projection, simulations) do
    nodes = projection["phases"] |> Enum.flat_map(& &1["nodes"])

    %{
      node_count: length(nodes),
      exact_count: Enum.count(nodes, &(&1["confidence"] == "exact")),
      opaque_count: Enum.count(nodes, &(&1["confidence"] == "opaque")),
      simulation_count: length(simulations),
      trace_event_count: simulations |> Enum.flat_map(& &1["trace"]) |> length(),
      review_count:
        length(projection["conflicts"]) + length(projection["opaque_regions"]) +
          length(projection["warnings"])
    }
  end

  defp first_node(projection) do
    projection["phases"]
    |> List.first()
    |> Map.get("nodes", [])
    |> List.first()
  end

  defp runtime_event_label(nil), do: "No runtime events observed"
  defp runtime_event_label(event), do: event["type"]

  defp runtime_event_detail(event) do
    [
      event["model_id"],
      event["session_id"],
      event["receipt_id"],
      event["selected_model"]
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" / ")
  end

  defp policy_cache_event_detail(event) do
    scope =
      event
      |> Map.get("scope", %{})
      |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)
      |> Enum.join(", ")

    cond do
      scope != "" ->
        scope

      true ->
        "global scope"
    end
  end

  defp normalize_pattern(nil), do: "tts-retry"

  defp normalize_pattern(pattern_id) do
    if Enum.any?(Wardwright.PolicyProjection.patterns(), &(&1["id"] == pattern_id)) do
      pattern_id
    else
      "tts-retry"
    end
  end

  defp normalize_mode(mode) when mode in @modes, do: mode
  defp normalize_mode(_), do: "phase_map"

  defp path(pattern_id, mode), do: "/policies/#{pattern_id}/#{mode}"

  defp mode_label("phase_map"), do: "Phase map"
  defp mode_label("effect_matrix"), do: "Effect matrix"
  defp mode_label("trace_overlay"), do: "Trace overlay"

  defp node_label(projection, node_id) do
    projection["phases"]
    |> Enum.flat_map(& &1["nodes"])
    |> Enum.find(%{"label" => node_id}, &(&1["id"] == node_id))
    |> Map.get("label")
  end
end
