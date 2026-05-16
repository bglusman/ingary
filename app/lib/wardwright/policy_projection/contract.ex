defmodule Wardwright.PolicyProjection.Contract do
  @moduledoc """
  Typed projection records at the boundary between policy semantics and UI maps.

  LiveView and JSON contracts still receive string-keyed maps. Core projection
  code should construct these structs first, then serialize at the boundary.
  """

  defmodule Node do
    @moduledoc false
    @enforce_keys [:id, :label, :node_class, :phase, :summary, :confidence]
    defstruct [
      :id,
      :label,
      :node_class,
      :phase,
      :summary,
      :confidence,
      reads: [],
      writes: [],
      actions: [],
      annotations: %{},
      source_span: nil
    ]
  end

  defmodule Annotation do
    @moduledoc false
    @enforce_keys [:why, :change_when, :review_hint]
    defstruct [:why, :change_when, :review_hint]
  end

  defmodule Effect do
    @moduledoc false
    @enforce_keys [:id, :node_id, :phase, :effect, :target, :confidence]
    defstruct [:id, :node_id, :phase, :effect, :target, :confidence]
  end

  defmodule TraceEvent do
    @moduledoc false
    @enforce_keys [:id, :phase, :node_id, :kind, :label, :detail, :severity]
    defstruct [
      :id,
      :phase,
      :node_id,
      :kind,
      :label,
      :detail,
      :severity,
      state_id: nil,
      source_span: nil
    ]
  end

  defmodule StateMachine do
    @moduledoc false
    @enforce_keys [:initial_state, :states]
    defstruct [
      :initial_state,
      states: [],
      transitions: [],
      simulation_steps: [],
      default_projection: true,
      summary: nil
    ]
  end

  defmodule State do
    @moduledoc false
    @enforce_keys [:id, :label, :summary]
    defstruct [:id, :label, :summary, node_ids: [], terminal: false]
  end

  defmodule Transition do
    @moduledoc false
    @enforce_keys [:id, :from, :to, :trigger, :action]
    defstruct [:id, :from, :to, :trigger, :action, :node_id, confidence: "exact"]
  end

  defmodule StateStep do
    @moduledoc false
    @enforce_keys [:step, :state, :event_id, :summary]
    defstruct [:step, :state, :event_id, :summary, :node_id, severity: "info"]
  end

  def to_map(%Node{} = node) do
    [
      {"id", node.id},
      {"label", node.label},
      {"kind", node.node_class},
      {"node_class", node.node_class},
      {"phase", node.phase},
      {"summary", node.summary},
      {"confidence", node.confidence},
      {"reads", node.reads},
      {"writes", node.writes},
      {"actions", node.actions},
      {"annotations", to_map(node.annotations)},
      {"source_span", node.source_span}
    ]
    |> reject_nil()
  end

  def to_map(%Annotation{} = annotation) do
    [
      {"why", annotation.why},
      {"change_when", annotation.change_when},
      {"review_hint", annotation.review_hint}
    ]
    |> reject_nil()
  end

  def to_map(%Effect{} = effect) do
    [
      {"id", effect.id},
      {"node_id", effect.node_id},
      {"phase", effect.phase},
      {"effect", effect.effect},
      {"target", effect.target},
      {"confidence", effect.confidence}
    ]
    |> reject_nil()
  end

  def to_map(%TraceEvent{} = event) do
    [
      {"id", event.id},
      {"phase", event.phase},
      {"node_id", event.node_id},
      {"kind", event.kind},
      {"label", event.label},
      {"detail", event.detail},
      {"severity", event.severity},
      {"state_id", event.state_id},
      {"source_span", event.source_span}
    ]
    |> reject_nil()
  end

  def to_map(%StateMachine{} = state_machine) do
    [
      {"schema", "wardwright.policy_state_machine.v1"},
      {"default_projection", state_machine.default_projection},
      {"initial_state", state_machine.initial_state},
      {"summary", state_machine.summary},
      {"states", Enum.map(state_machine.states, &to_map/1)},
      {"transitions", Enum.map(state_machine.transitions, &to_map/1)},
      {"simulation_steps", Enum.map(state_machine.simulation_steps, &to_map/1)}
    ]
    |> reject_nil()
  end

  def to_map(%State{} = state) do
    [
      {"id", state.id},
      {"label", state.label},
      {"summary", state.summary},
      {"node_ids", state.node_ids},
      {"terminal", state.terminal}
    ]
    |> reject_nil()
  end

  def to_map(%Transition{} = transition) do
    [
      {"id", transition.id},
      {"from", transition.from},
      {"to", transition.to},
      {"trigger", transition.trigger},
      {"action", transition.action},
      {"node_id", transition.node_id},
      {"confidence", transition.confidence}
    ]
    |> reject_nil()
  end

  def to_map(%StateStep{} = step) do
    [
      {"step", step.step},
      {"state", step.state},
      {"event_id", step.event_id},
      {"node_id", step.node_id},
      {"summary", step.summary},
      {"severity", step.severity}
    ]
    |> reject_nil()
  end

  defp reject_nil(pairs) do
    pairs
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
