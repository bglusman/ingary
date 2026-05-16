defmodule WardwrightWeb.PolicyProjectionLive do
  @moduledoc false

  use Phoenix.LiveView

  @modes ["diagram", "phase_map", "state_machine", "effect_matrix", "trace_overlay"]

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
    recipe_source_id = normalize_recipe_source(Map.get(params, "source"))
    recipe_catalog = recipe_catalog(recipe_source_id)
    projection = Wardwright.PolicyProjection.projection(pattern_id)
    simulations = Wardwright.PolicyProjection.simulations(pattern_id)
    selected_simulation = List.first(simulations)
    selected_node = first_node(projection)
    simulation_step = normalize_step(Map.get(params, "step"), selected_simulation)

    socket
    |> assign(:page_title, "Policy Workbench")
    |> assign(:modes, @modes)
    |> assign(:recipe_sources, recipe_sources())
    |> assign(:selected_recipe_source_id, recipe_source_id)
    |> assign(:recipe_catalog, recipe_catalog)
    |> assign(:patterns, recipe_catalog["recipes"])
    |> assign(:selected_pattern, Wardwright.PolicyProjection.pattern(pattern_id))
    |> assign(:selected_pattern_id, pattern_id)
    |> assign(:mode, mode)
    |> assign(:projection, projection)
    |> assign(:simulations, simulations)
    |> assign(:projection_stats, projection_stats(projection, simulations))
    |> assign(:selected_simulation, selected_simulation)
    |> assign(:selected_node, selected_node)
    |> assign(:simulation_playing, false)
    |> assign(:simulation_step, simulation_step)
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
  def handle_info(:advance_simulation, socket) do
    if socket.assigns.simulation_playing do
      trace_count = trace_count(socket.assigns.selected_simulation)
      next_step = min(socket.assigns.simulation_step + 1, trace_count)
      playing = next_step < trace_count

      socket =
        socket
        |> assign(:simulation_step, next_step)
        |> assign(:simulation_playing, playing)

      if playing do
        schedule_simulation_tick()
      end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("play-simulation", _params, socket) do
    trace_count = trace_count(socket.assigns.selected_simulation)

    socket =
      socket
      |> assign(
        :simulation_playing,
        trace_count > 0 and socket.assigns.simulation_step < trace_count
      )

    if socket.assigns.simulation_playing do
      schedule_simulation_tick()
    end

    {:noreply, socket}
  end

  def handle_event("select-recipe-source", %{"recipe_source" => source_id}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         path(
           socket.assigns.selected_pattern_id,
           socket.assigns.mode,
           normalize_recipe_source(source_id)
         )
     )}
  end

  def handle_event("pause-simulation", _params, socket) do
    {:noreply, assign(socket, :simulation_playing, false)}
  end

  def handle_event("reset-simulation", _params, socket) do
    {:noreply, assign(socket, simulation_playing: false, simulation_step: 0)}
  end

  def handle_event("step-simulation", _params, socket) do
    trace_count = trace_count(socket.assigns.selected_simulation)

    {:noreply,
     socket
     |> assign(:simulation_playing, false)
     |> assign(:simulation_step, min(socket.assigns.simulation_step + 1, trace_count))}
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
        <form class="recipe_source" phx-change="select-recipe-source">
          <label for="recipe_source">Recipe source</label>
          <select id="recipe_source" name="recipe_source">
            <option
              :for={source <- @recipe_sources}
              value={source["id"]}
              selected={source["id"] == @selected_recipe_source_id}
            >
              <%= source["label"] %>
            </option>
          </select>
          <small><%= @recipe_catalog["source"]["endpoint"] || "compiled into this build" %></small>
          <small>Community hub: wardwright.dev/recipes</small>
          <span class="recipe_source_status"><%= recipe_catalog_status(@recipe_catalog) %></span>
        </form>

        <a
          :for={pattern <- @patterns}
          class={if pattern["pattern_id"] == @selected_pattern_id, do: "active", else: ""}
          href={path(pattern["pattern_id"], @mode, @selected_recipe_source_id)}
        >
          <strong><%= pattern["title"] %></strong>
          <span><%= pattern["category"] %></span>
        </a>
        <div :if={@patterns == []} class="recipe_empty">
          <strong>No recipes loaded</strong>
          <span><%= recipe_catalog_status(@recipe_catalog) %></span>
        </div>
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
          <span>State model</span>
          <strong><%= @projection_stats.state_count %> states</strong>
          <small><%= @projection_stats.transition_count %> transitions</small>
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
          <a
            :for={mode <- @modes}
            class={if mode == @mode, do: "active", else: ""}
            href={path(@selected_pattern_id, mode, @selected_recipe_source_id)}
          >
            <%= mode_label(mode) %>
          </a>
        </div>

        <%= if @mode == "diagram" do %>
          <.policy_diagram
            projection={@projection}
            simulation={@selected_simulation}
            playback_step={@simulation_step}
            playing={@simulation_playing}
          />
        <% else %>
        <%= if @mode == "effect_matrix" do %>
          <.effect_matrix projection={@projection} />
        <% else %>
          <%= if @mode == "trace_overlay" do %>
            <.trace_overlay projection={@projection} simulation={@selected_simulation} />
          <% else %>
            <%= if @mode == "state_machine" do %>
              <.state_machine_view projection={@projection} />
            <% else %>
              <.phase_map projection={@projection} />
            <% end %>
          <% end %>
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
  attr(:simulation, :map, required: true)
  attr(:playback_step, :integer, required: true)
  attr(:playing, :boolean, required: true)

  def policy_diagram(assigns) do
    assigns =
      assigns
      |> assign(:diagram, diagram(assigns.projection, assigns.simulation, assigns.playback_step))
      |> assign(:current_event, current_trace_event(assigns.simulation, assigns.playback_step))
      |> assign(:trace_count, trace_count(assigns.simulation))

    ~H"""
    <div class="diagram_shell">
      <div class="diagram_header">
        <div>
          <strong>Projection graph</strong>
          <span>Nodes are backend projection facts; edges show order, state transitions, effects, conflicts, and simulated execution.</span>
        </div>
        <div class="diagram_legend">
          <span><i class="legend_shape primitive"></i>primitive</span>
          <span><i class="legend_shape arbiter"></i>arbiter</span>
          <span><i class="legend_shape rule"></i>rule</span>
          <span><i class="legend_shape receipt"></i>receipt</span>
          <span><i class="legend_dot exact"></i>exact</span>
          <span><i class="legend_dot inferred"></i>declared</span>
          <span><i class="legend_line trace"></i>simulated path</span>
          <span><i class="legend_line conflict"></i>conflict</span>
        </div>
      </div>

      <div class="simulation_player" aria-label="Simulation playback">
        <div class="player_status">
          <strong>Simulated stream playback</strong>
          <span><%= simulation_status(@current_event, @playback_step, @trace_count) %></span>
        </div>
        <div class="player_meter" aria-label={"Simulation step #{@playback_step} of #{@trace_count}"}>
          <span style={"width: #{simulation_progress(@playback_step, @trace_count)}%;"}></span>
        </div>
        <div class="player_controls">
          <button type="button" phx-click={if @playing, do: "pause-simulation", else: "play-simulation"}>
            <%= if @playing, do: "Pause", else: "Play" %>
          </button>
          <button type="button" phx-click="step-simulation">Step</button>
          <button type="button" phx-click="reset-simulation">Reset</button>
        </div>
        <div class="player_event">
          <.badge value={if @current_event, do: @current_event["kind"], else: "ready"} />
          <strong><%= if @current_event, do: @current_event["label"], else: "waiting at input boundary" %></strong>
          <span><%= if @current_event, do: @current_event["detail"], else: @simulation["input_summary"] %></span>
        </div>
      </div>

      <div class="diagram_canvas">
        <svg
          role="img"
          aria-label="Policy projection graph"
          viewBox={"0 0 #{@diagram.width} #{@diagram.height}"}
          preserveAspectRatio="xMinYMin meet"
        >
          <defs>
            <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
              <path d="M 0 0 L 10 5 L 0 10 z" class="arrow_fill" />
            </marker>
            <marker id="trace-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
              <path d="M 0 0 L 10 5 L 0 10 z" class="trace_fill" />
            </marker>
          </defs>

          <g class="phase_bands">
            <g :for={phase <- @diagram.phases}>
              <rect x={phase.x} y="42" width={phase.width} height={@diagram.height - 92} rx="10" class="phase_band" />
              <text x={phase.x + 16} y="70" class="phase_title"><%= phase.title %></text>
              <text x={phase.x + 16} y="91" class="phase_caption"><%= phase.id %></text>
            </g>
          </g>

          <g class="diagram_edges">
            <line
              :for={edge <- @diagram.edges}
              x1={edge.x1}
              y1={edge.y1}
              x2={edge.x2}
              y2={edge.y2}
              class={"diagram_edge #{edge.kind} #{if edge.active, do: "active", else: ""}"}
              marker-end={edge.marker}
            />
          </g>

          <g class="diagram_effects">
            <g :for={effect <- @diagram.effects}>
              <path d={pill_path(effect)} class={"effect_node #{effect.confidence}"} />
              <text x={effect.x + 10} y={effect.y + 18} class="effect_title"><%= effect.effect %></text>
              <text x={effect.x + 10} y={effect.y + 35} class="effect_caption"><%= effect.target %></text>
            </g>
          </g>

          <g class="diagram_nodes">
            <g :for={node <- @diagram.nodes}>
              <path d={node_path(node)} class={"diagram_node #{node.shape} #{node.confidence} #{if node.executed, do: "executed", else: ""} #{if node.active, do: "active", else: ""}"} />
              <text x={node.x + 12} y={node.y + 21} class="node_title"><%= node.label %></text>
              <text x={node.x + 12} y={node.y + 42} class="node_kind"><%= node.kind %></text>
              <text :for={{line, index} <- Enum.with_index(node.summary_lines)} x={node.x + 12} y={node.y + 62 + index * 16} class="node_summary">
                <%= line %>
              </text>
            </g>
          </g>
        </svg>
      </div>

      <div class="diagram_trace">
        <article :for={{event, index} <- Enum.with_index(@simulation["trace"], 1)} class={"trace_event #{event["severity"]} #{trace_step_class(index, @playback_step)}"}>
          <span><%= event["phase"] %></span>
          <strong><%= event["label"] %></strong>
          <.badge value={event["kind"]} />
          <small><%= event["detail"] %></small>
        </article>
      </div>
    </div>
    """
  end

  attr(:projection, :map, required: true)

  def state_machine_view(assigns) do
    ~H"""
    <div class="state_machine">
      <div class="state_machine_summary">
        <div>
          <strong><%= @projection["state_machine"]["schema"] %></strong>
          <span><%= @projection["state_machine"]["summary"] %></span>
        </div>
        <.badge value={if @projection["state_machine"]["default_projection"], do: "default one-state", else: "explicit stateful"} />
      </div>

      <div class="state_grid">
        <article :for={state <- @projection["state_machine"]["states"]} class={"state_card #{if state["terminal"], do: "terminal", else: ""}"}>
          <div>
            <strong><%= state["label"] %></strong>
            <.badge value={if state["id"] == @projection["state_machine"]["initial_state"], do: "initial", else: "state"} />
          </div>
          <span><%= state["summary"] %></span>
          <small><%= Enum.join(state["node_ids"], ", ") %></small>
        </article>
      </div>

      <div class="state_columns">
        <section>
          <h3>Transitions</h3>
          <div class="transition_list">
            <article :for={transition <- @projection["state_machine"]["transitions"]} class="transition_row">
              <span><%= transition["id"] %>: <%= transition["from"] %> -> <%= transition["to"] %></span>
              <strong><%= transition["trigger"] %></strong>
              <small><%= transition["action"] %> via <%= transition["node_id"] %></small>
            </article>
            <article :if={@projection["state_machine"]["transitions"] == []} class="transition_row empty">
              <span>active</span>
              <strong>No explicit transitions</strong>
              <small>This policy projects as a single active state until the artifact defines stateful control flow.</small>
            </article>
          </div>
        </section>

        <section>
          <h3>Simulation Path</h3>
          <div class="state_steps">
            <article :for={step <- @projection["state_machine"]["simulation_steps"]} class={"state_step #{step["severity"]}"}>
              <span><%= step["step"] %></span>
              <strong><%= step["state"] %></strong>
              <small><%= step["summary"] %></small>
            </article>
          </div>
        </section>
      </div>

      <div class="assistant_boundary">
        <div>
          <strong>Assistant boundary</strong>
          <span>Natural-language authoring can attach here as proposed tool calls, but this view is currently deterministic projection data only.</span>
        </div>
        <div class="chips">
          <span class="chip">explain_projection</span>
          <span class="chip">simulate_policy</span>
          <span class="chip">propose_rule_change</span>
          <span class="chip">validate_policy_artifact</span>
        </div>
      </div>
    </div>
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
    .recipe_source, .recipe_empty { display: grid; gap: 6px; margin-bottom: 4px; padding: 10px 12px; border: 1px solid #4d5f6f; border-radius: 6px; background: #2d3944; }
    .recipe_source label, .recipe_source span, .recipe_source small, .recipe_empty span { color: #adbac5; font-size: 12px; font-weight: 700; }
    .recipe_source select { min-width: 0; min-height: 32px; border: 1px solid #657583; border-radius: 6px; color: #e6ebef; background: #25313b; font-weight: 800; }
    .recipe_source_status { line-height: 1.35; }
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
    .scan_strip { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 10px; margin-bottom: 18px; }
    .scan_strip article { display: grid; gap: 4px; min-width: 0; padding: 12px; border: 1px solid #d3dbe2; border-radius: 8px; background: #fff; box-shadow: 0 1px 2px rgb(16 24 40 / 4%); }
    .scan_strip span { color: #66727c; font-size: 12px; font-weight: 800; text-transform: uppercase; }
    .scan_strip strong { color: #17202a; font-size: 18px; line-height: 1.2; }
    .scan_strip small { color: #5e6b76; line-height: 1.35; overflow-wrap: anywhere; }
    .mode_tabs { display: inline-flex; flex-wrap: wrap; gap: 4px; margin-bottom: 14px; padding: 4px; border: 1px solid #d5dde4; border-radius: 8px; background: #f3f6f8; }
    .mode_tabs a { border: 1px solid transparent; border-radius: 6px; padding: 7px 10px; color: #3a4650; font-size: 13px; font-weight: 800; }
    .mode_tabs a.active, .mode_tabs a:hover { border-color: #c5d0d9; background: #fff; }
    .diagram_shell { display: grid; gap: 12px; }
    .diagram_header { display: flex; align-items: flex-start; justify-content: space-between; gap: 14px; padding: 12px; border: 1px solid #d5dde4; border-radius: 8px; background: #fbfcfd; }
    .diagram_header > div:first-child { display: grid; gap: 4px; min-width: 0; }
    .diagram_header span { color: #5e6b76; font-size: 13px; line-height: 1.4; }
    .diagram_legend { display: flex; flex-wrap: wrap; justify-content: flex-end; gap: 8px 12px; max-width: 560px; }
    .diagram_legend span { display: inline-flex; align-items: center; gap: 5px; white-space: nowrap; }
    .legend_shape { display: inline-block; width: 18px; height: 12px; border: 1.5px solid #7f8d99; background: #fff; }
    .legend_shape.primitive { border-radius: 2px; border-color: #6f9fd1; background: #eef6ff; }
    .legend_shape.arbiter { clip-path: polygon(12% 0, 88% 0, 100% 50%, 88% 100%, 12% 100%, 0 50%); border-color: transparent; background: #e7ddf7; }
    .legend_shape.rule { border-radius: 8px; border-color: #72ad99; background: #edf8f3; }
    .legend_shape.receipt { border-radius: 1px; border-color: #9a8c65; background: #fff7df; }
    .legend_dot { width: 11px; height: 11px; border: 1px solid #94a3af; border-radius: 999px; background: #edf2f7; }
    .legend_dot.exact { border-color: #78b59f; background: #cfeee2; }
    .legend_dot.inferred { border-color: #d2aa49; background: #f7df9a; }
    .legend_dot.opaque { border-color: #cf7777; background: #f0b5b5; }
    .legend_line { width: 22px; height: 0; border-top: 3px solid #64748b; }
    .legend_line.trace { border-top-color: #2f74b5; }
    .legend_line.conflict { border-top-color: #b4232e; border-top-style: dashed; }
    .diagram_canvas { overflow: auto; border: 1px solid #d5dde4; border-radius: 8px; background: linear-gradient(180deg, #f8fafc, #f2f5f7); }
    .diagram_canvas svg { display: block; min-width: 860px; width: 100%; height: auto; }
    .phase_band { fill: #ffffff; stroke: #dbe3ea; stroke-width: 1; }
    .phase_title { fill: #26323c; font-size: 14px; font-weight: 800; }
    .phase_caption { fill: #6b7883; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 11px; }
    .diagram_edge { stroke: #8392a0; stroke-width: 2; }
    .diagram_edge.effect { stroke: #66727c; stroke-dasharray: 4 4; }
    .diagram_edge.state { stroke: #6e55a8; stroke-width: 2.4; }
    .diagram_edge.trace { stroke: #2f74b5; stroke-width: 4; stroke-linecap: round; opacity: 0.82; }
    .diagram_edge.trace.active { stroke: #0b5cad; stroke-width: 6; opacity: 1; }
    .diagram_edge.conflict { stroke: #b4232e; stroke-width: 2.4; stroke-dasharray: 7 5; }
    .arrow_fill { fill: #66727c; }
    .trace_fill { fill: #2f74b5; }
    .diagram_node { fill: #f7f9fb; stroke: #aebbc6; stroke-width: 1.4; }
    .diagram_node.primitive { fill: #eef6ff; stroke: #6f9fd1; }
    .diagram_node.arbiter { fill: #f3effb; stroke: #876cbd; }
    .diagram_node.rule { fill: #edf8f3; stroke: #72ad99; }
    .diagram_node.receipt { fill: #fff7df; stroke: #c5a650; }
    .diagram_node.plan_gap { fill: #f7f9fb; stroke: #9aa8b4; stroke-dasharray: 6 4; }
    .diagram_node.declared, .diagram_node.inferred { stroke-width: 1.8; }
    .diagram_node.opaque { fill: #fff1f1; stroke: #cf7777; }
    .diagram_node.executed { stroke: #2f74b5; stroke-width: 3; }
    .diagram_node.active { fill: #e4f1ff; stroke: #0b5cad; stroke-width: 4; }
    .effect_node { fill: #ffffff; stroke: #b7c2cc; stroke-width: 1.2; }
    .effect_node.exact { fill: #f0faf6; stroke: #94c7b5; }
    .effect_node.declared, .effect_node.inferred { fill: #fffaf0; stroke: #d9bd72; }
    .effect_node.opaque { fill: #fff5f5; stroke: #df9a9a; }
    .node_title, .effect_title { fill: #17202a; font-size: 13px; font-weight: 800; }
    .node_kind, .effect_caption { fill: #5e6b76; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 11px; }
    .node_summary { fill: #4c5964; font-size: 11px; }
    .diagram_trace { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 9px; }
    .simulation_player { display: grid; grid-template-columns: minmax(0, 1fr) max-content; gap: 10px 14px; align-items: center; padding: 12px; border: 1px solid #d5dde4; border-radius: 8px; background: #fbfcfd; }
    .player_status, .player_event { display: grid; gap: 4px; min-width: 0; }
    .player_status span, .player_event span { color: #5e6b76; font-size: 13px; line-height: 1.4; }
    .player_meter { grid-column: 1 / -1; height: 10px; overflow: hidden; border: 1px solid #bfd0df; border-radius: 999px; background: #edf2f7; }
    .player_meter span { display: block; height: 100%; border-radius: inherit; background: #2f74b5; transition: width 180ms ease; }
    .player_controls { display: inline-flex; flex-wrap: wrap; justify-content: flex-end; gap: 6px; }
    .player_controls button { min-height: 32px; padding: 5px 10px; border: 1px solid #c5d0d9; border-radius: 6px; color: #26323c; background: #fff; font-weight: 800; cursor: pointer; }
    .player_controls button:hover { border-color: #8fa1b2; background: #f3f6f8; }
    .player_event { grid-column: 1 / -1; grid-template-columns: max-content minmax(0, 0.3fr) minmax(0, 1fr); align-items: center; padding: 10px; border: 1px solid #dbe2e8; border-radius: 8px; background: #fff; }
    .trace_event.pending { opacity: 0.46; }
    .trace_event.active { border-color: #84b9e8; background: #eef6ff; }
    .phase_grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px; }
    .phase_column, .node_stack, .timeline, .finding_list, .trace_overlay, .effect_matrix, .chips, .state_machine, .transition_list, .state_steps { display: grid; gap: 9px; }
    .phase_header, .node_card, .finding, .trace_event, .trace_summary, .effect_row, .state_machine_summary, .state_card, .transition_row, .state_step, .assistant_boundary { padding: 12px; border: 1px solid #d5dde4; border-radius: 8px; background: #fbfcfd; }
    .phase_header span, .node_card span, .trace_summary span, .finding span, .trace_event small, .state_machine_summary span, .state_card span, .state_card small, .transition_row small, .assistant_boundary span { color: #5e6b76; font-size: 13px; line-height: 1.4; }
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
    .state_machine_summary, .assistant_boundary { display: flex; align-items: flex-start; justify-content: space-between; gap: 14px; }
    .state_machine_summary > div, .assistant_boundary > div:first-child { display: grid; gap: 4px; min-width: 0; }
    .state_grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 10px; }
    .state_card { display: grid; gap: 8px; min-height: 126px; }
    .state_card div { display: flex; align-items: flex-start; justify-content: space-between; gap: 8px; }
    .state_card.terminal { border-color: #94c7b5; background: #f0faf6; }
    .state_columns { display: grid; grid-template-columns: minmax(0, 1fr) minmax(280px, 0.8fr); gap: 14px; }
    .transition_row { display: grid; gap: 4px; }
    .transition_row > span { color: #66727c; font-size: 12px; font-weight: 800; text-transform: uppercase; }
    .transition_row.empty { border-style: dashed; }
    .state_step { display: grid; grid-template-columns: 32px minmax(0, 0.6fr) minmax(0, 1fr); gap: 9px; align-items: center; }
    .state_step > span { display: inline-grid; place-items: center; width: 28px; height: 28px; border-radius: 999px; color: #fff; background: #506170; font-size: 12px; font-weight: 800; }
    .state_step.pass { border-color: #94c7b5; background: #f0faf6; }
    .state_step.warn { border-color: #d9bd72; background: #fffaf0; }
    .state_step.block { border-color: #df9a9a; background: #fff5f5; }
    .badge { display: inline-flex; align-items: center; width: fit-content; max-width: 100%; min-height: 24px; padding: 3px 8px; border: 1px solid #cad4dc; border-radius: 999px; color: #33414c; background: #f5f7f9; font-size: 12px; font-weight: 800; line-height: 1.2; white-space: nowrap; }
    .schema_badge { overflow-wrap: normal; }
    .badge.exact, .badge.executed, .badge.passed, .badge.pass { border-color: #94c7b5; color: #1c654f; background: #edf8f3; }
    .badge.declared, .badge.inferred, .badge.inconclusive, .badge.warning, .badge.warn { border-color: #d9bd72; color: #73570d; background: #fff7df; }
    .badge.opaque, .badge.failed, .badge.block, .badge.conflicting { border-color: #df9a9a; color: #8b2d2d; background: #fff1f1; }
    pre, code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
    pre { max-height: 380px; overflow: auto; padding: 12px; border: 1px solid #dbe2e8; border-radius: 6px; color: #25313b; background: #f7f9fb; font-size: 12px; line-height: 1.45; }
    @media (max-width: 980px) { .shell > [data-phx-main], .split, .scan_strip, .state_columns, .simulation_player, .player_event { grid-template-columns: 1fr; } .sidebar { position: sticky; top: 0; z-index: 1; } .topbar, .panel_header, .state_machine_summary, .assistant_boundary, .diagram_header { display: grid; } .diagram_legend, .player_controls { justify-content: flex-start; } .effect_row, .trace_event, .state_step { grid-template-columns: 1fr; } .trace_event small, .trace_summary span { grid-column: 1; } .engine_card { min-width: 0; } .schema_badge { white-space: normal; overflow-wrap: anywhere; } }
    """
  end

  defp projection_stats(projection, simulations) do
    nodes = projection["phases"] |> Enum.flat_map(& &1["nodes"])

    %{
      node_count: length(nodes),
      exact_count: Enum.count(nodes, &(&1["confidence"] == "exact")),
      opaque_count: Enum.count(nodes, &(&1["confidence"] == "opaque")),
      state_count: length(projection["state_machine"]["states"]),
      transition_count: length(projection["state_machine"]["transitions"]),
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

  defp schedule_simulation_tick do
    Process.send_after(self(), :advance_simulation, 900)
  end

  defp trace_count(nil), do: 0

  defp trace_count(simulation) do
    simulation
    |> Map.get("trace", [])
    |> length()
  end

  defp current_trace_event(_simulation, 0), do: nil
  defp current_trace_event(nil, _step), do: nil

  defp current_trace_event(simulation, step) do
    simulation
    |> Map.get("trace", [])
    |> Enum.at(max(step - 1, 0))
  end

  defp simulation_status(_event, 0, trace_count) do
    "Ready: #{trace_count} trace events available for playback."
  end

  defp simulation_status(event, step, trace_count) do
    state =
      event
      |> Map.get("state_id")
      |> case do
        nil -> "state unavailable"
        state_id -> "state #{state_id}"
      end

    "Step #{step} of #{trace_count}: #{state}, #{event["phase"]}."
  end

  defp simulation_progress(_step, 0), do: 0
  defp simulation_progress(step, trace_count), do: div(min(step, trace_count) * 100, trace_count)

  defp trace_step_class(index, playback_step) when index < playback_step, do: "completed"
  defp trace_step_class(index, playback_step) when index == playback_step, do: "active"
  defp trace_step_class(_index, _playback_step), do: "pending"

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

  defp normalize_recipe_source(nil), do: "built_in"

  defp normalize_recipe_source(source_id) do
    if source_id in Wardwright.PolicyRecipeCatalog.source_ids() do
      source_id
    else
      "built_in"
    end
  end

  defp recipe_sources do
    Wardwright.PolicyRecipeCatalog.sources()
    |> Enum.map(&Wardwright.PolicyRecipeCatalog.to_map/1)
  end

  defp recipe_catalog(source_id) do
    case Wardwright.PolicyRecipeCatalog.list(source_id) do
      {:ok, catalog} ->
        Wardwright.PolicyRecipeCatalog.to_map(catalog)

      {:error, catalog} ->
        catalog
        |> Wardwright.PolicyRecipeCatalog.to_map()
        |> then(&Map.put(&1, "warnings", [&1["error"]]))
    end
  end

  defp recipe_catalog_status(%{"error" => error}), do: error

  defp recipe_catalog_status(%{"recipes" => recipes, "warnings" => [warning | _]}) do
    "#{length(recipes)} recipes. #{warning}"
  end

  defp recipe_catalog_status(%{"recipes" => recipes}), do: "#{length(recipes)} recipes available."

  defp normalize_step(nil, _simulation), do: 0

  defp normalize_step(step, simulation) when is_binary(step) do
    case Integer.parse(step) do
      {parsed, ""} -> normalize_step(parsed, simulation)
      _ -> 0
    end
  end

  defp normalize_step(step, simulation) when is_integer(step) do
    step
    |> max(0)
    |> min(trace_count(simulation))
  end

  defp normalize_step(_step, _simulation), do: 0

  defp path(pattern_id, mode), do: "/policies/#{pattern_id}/#{mode}"

  defp path(pattern_id, mode, "built_in"), do: path(pattern_id, mode)

  defp path(pattern_id, mode, source_id) do
    path(pattern_id, mode) <> "?" <> URI.encode_query(%{"source" => source_id})
  end

  defp mode_label("diagram"), do: "Diagram"
  defp mode_label("phase_map"), do: "Phase map"
  defp mode_label("state_machine"), do: "State machine"
  defp mode_label("effect_matrix"), do: "Effect matrix"
  defp mode_label("trace_overlay"), do: "Trace overlay"

  defp diagram(projection, simulation, playback_step) do
    phases = diagram_phases(projection["phases"])
    nodes = diagram_nodes(projection["phases"], phases, simulation, playback_step)
    node_index = Map.new(nodes, &{&1.id, &1})
    effects = diagram_effects(projection["effects"], node_index)

    %{
      width: diagram_width(phases),
      height: diagram_height(nodes, effects),
      phases: phases,
      nodes: nodes,
      effects: effects,
      edges:
        diagram_sequence_edges(nodes) ++
          diagram_effect_edges(effects, node_index) ++
          diagram_state_edges(
            projection["state_machine"]["transitions"],
            projection["state_machine"]["states"],
            node_index
          ) ++
          diagram_conflict_edges(projection["conflicts"], node_index) ++
          diagram_trace_edges(simulation["trace"], node_index, playback_step)
    }
  end

  defp diagram_phases(phases) do
    phases
    |> Enum.with_index()
    |> Enum.map(fn {phase, index} ->
      %{
        id: phase["id"],
        title: phase["title"],
        x: 32 + index * 366,
        width: 330
      }
    end)
  end

  defp diagram_nodes(projection_phases, phases, simulation, playback_step) do
    executed =
      simulation["trace"]
      |> Enum.take(playback_step)
      |> Enum.map(& &1["node_id"])
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    active_node_id = current_trace_event(simulation, playback_step) |> active_node_id()
    phase_x = Map.new(phases, &{&1.id, &1.x})

    projection_phases
    |> Enum.flat_map(fn phase ->
      phase["nodes"]
      |> Enum.with_index()
      |> Enum.map(fn {node, index} ->
        %{
          id: node["id"],
          label: node["label"],
          kind: node["kind"],
          shape: node_shape(node["kind"]),
          phase: phase["id"],
          confidence: node["confidence"],
          executed: MapSet.member?(executed, node["id"]),
          active: node["id"] == active_node_id,
          x: Map.fetch!(phase_x, phase["id"]) + 18,
          y: 112 + index * 134,
          width: 196,
          height: 98,
          summary_lines: summary_lines(node["summary"])
        }
      end)
    end)
  end

  defp active_node_id(nil), do: nil
  defp active_node_id(event), do: event["node_id"]

  defp node_shape(kind) when kind in ["primitive", "tool_selector"], do: "primitive"
  defp node_shape(kind) when kind in ["arbiter", "tool_loop_threshold"], do: "arbiter"
  defp node_shape("receipt_rule"), do: "receipt"
  defp node_shape("plan_gap"), do: "plan_gap"
  defp node_shape(_kind), do: "rule"

  defp node_path(%{shape: "arbiter"} = node) do
    x = node.x
    y = node.y
    w = node.width
    h = node.height
    notch = 18

    "M #{x + notch} #{y} L #{x + w - notch} #{y} L #{x + w} #{y + div(h, 2)} L #{x + w - notch} #{y + h} L #{x + notch} #{y + h} L #{x} #{y + div(h, 2)} Z"
  end

  defp node_path(%{shape: "receipt"} = node) do
    x = node.x
    y = node.y
    w = node.width
    h = node.height
    fold = 18

    "M #{x} #{y} L #{x + w - fold} #{y} L #{x + w} #{y + fold} L #{x + w} #{y + h} L #{x} #{y + h} Z"
  end

  defp node_path(node) do
    rounded_rect_path(node.x, node.y, node.width, node.height, 12)
  end

  defp pill_path(node) do
    rounded_rect_path(node.x, node.y, node.width, node.height, div(node.height, 2))
  end

  defp rounded_rect_path(x, y, width, height, radius) do
    right = x + width
    bottom = y + height

    "M #{x + radius} #{y} L #{right - radius} #{y} Q #{right} #{y} #{right} #{y + radius} L #{right} #{bottom - radius} Q #{right} #{bottom} #{right - radius} #{bottom} L #{x + radius} #{bottom} Q #{x} #{bottom} #{x} #{bottom - radius} L #{x} #{y + radius} Q #{x} #{y} #{x + radius} #{y} Z"
  end

  defp diagram_effects(effects, node_index) do
    effects
    |> Enum.group_by(& &1["node_id"])
    |> Enum.flat_map(fn {node_id, grouped_effects} ->
      node = Map.get(node_index, node_id)

      grouped_effects
      |> Enum.with_index()
      |> Enum.flat_map(fn {effect, index} ->
        if node do
          [
            %{
              id: effect["id"],
              node_id: node_id,
              effect: effect["effect"],
              target: effect["target"],
              confidence: effect["confidence"],
              x: node.x + node.width + 20,
              y: node.y + index * 62,
              width: 96,
              height: 52
            }
          ]
        else
          []
        end
      end)
    end)
  end

  defp diagram_width([]), do: 720

  defp diagram_width(phases) do
    phases
    |> List.last()
    |> then(&max(&1.x + &1.width + 32, 860))
  end

  defp diagram_height(nodes, effects) do
    bottom =
      (nodes ++ effects)
      |> Enum.map(&(&1.y + &1.height))
      |> Enum.max(fn -> 260 end)

    max(bottom + 58, 340)
  end

  defp diagram_sequence_edges([]), do: []

  defp diagram_sequence_edges(nodes) do
    nodes
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from, to] ->
      edge(right_center(from), left_center(to), "sequence", "url(#arrow)")
    end)
  end

  defp diagram_effect_edges(effects, node_index) do
    effects
    |> Enum.flat_map(fn effect_node ->
      case Map.fetch(node_index, effect_node.node_id) do
        {:ok, node} ->
          [edge(right_center(node), left_center(effect_node), "effect", "url(#arrow)")]

        :error ->
          []
      end
    end)
  end

  defp diagram_state_edges(transitions, states, node_index) do
    state_first_node =
      states
      |> Enum.flat_map(fn state ->
        case List.first(state["node_ids"]) do
          nil -> []
          node_id -> [{state["id"], node_id}]
        end
      end)
      |> Map.new()

    transitions
    |> Enum.flat_map(fn transition ->
      with from_id when is_binary(from_id) <- transition["node_id"],
           to_id when is_binary(to_id) <- Map.get(state_first_node, transition["to"]),
           from when not is_nil(from) <- Map.get(node_index, from_id),
           to when not is_nil(to) <- Map.get(node_index, to_id),
           false <- from.id == to.id do
        [edge(bottom_center(from), top_center(to), "state", "url(#arrow)")]
      else
        _ -> []
      end
    end)
  end

  defp diagram_conflict_edges(conflicts, node_index) do
    conflicts
    |> Enum.flat_map(fn conflict ->
      conflict["node_ids"]
      |> Enum.map(&Map.get(node_index, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.take(2)
      |> case do
        [from, to] -> [edge(top_center(from), top_center(to), "conflict", nil)]
        _ -> []
      end
    end)
  end

  defp diagram_trace_edges(trace, node_index, playback_step) do
    trace
    |> Enum.take(playback_step)
    |> Enum.map(& &1["node_id"])
    |> Enum.reject(&is_nil/1)
    |> Enum.chunk_by(& &1)
    |> Enum.map(&hd/1)
    |> Enum.map(&Map.get(node_index, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from, to] ->
      edge(bottom_center(from), bottom_center(to), "trace", "url(#trace-arrow)", true)
    end)
  end

  defp edge(from, to, kind, marker, active \\ false)

  defp edge({x1, y1}, {x2, y2}, kind, marker, active) do
    %{x1: x1, y1: y1, x2: x2, y2: y2, kind: kind, marker: marker, active: active}
  end

  defp left_center(box), do: {box.x, box.y + div(box.height, 2)}
  defp right_center(box), do: {box.x + box.width, box.y + div(box.height, 2)}
  defp top_center(box), do: {box.x + div(box.width, 2), box.y}
  defp bottom_center(box), do: {box.x + div(box.width, 2), box.y + box.height}

  defp summary_lines(nil), do: []

  defp summary_lines(summary) do
    summary
    |> String.split()
    |> Enum.reduce([""], fn word, [line | rest] ->
      candidate = String.trim("#{line} #{word}")

      if String.length(candidate) > 32 do
        [word, line | rest]
      else
        [candidate | rest]
      end
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.take(2)
  end

  defp node_label(projection, node_id) do
    projection["phases"]
    |> Enum.flat_map(& &1["nodes"])
    |> Enum.find(%{"label" => node_id}, &(&1["id"] == node_id))
    |> Map.get("label")
  end
end
