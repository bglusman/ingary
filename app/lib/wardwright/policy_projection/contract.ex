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
      source_span: nil
    ]
  end

  defmodule Effect do
    @moduledoc false
    @enforce_keys [:id, :node_id, :phase, :effect, :target, :confidence]
    defstruct [:id, :node_id, :phase, :effect, :target, :confidence]
  end

  defmodule TraceEvent do
    @moduledoc false
    @enforce_keys [:id, :phase, :node_id, :kind, :label, :detail, :severity]
    defstruct [:id, :phase, :node_id, :kind, :label, :detail, :severity, source_span: nil]
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
      {"source_span", node.source_span}
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
      {"source_span", event.source_span}
    ]
    |> reject_nil()
  end

  defp reject_nil(pairs) do
    pairs
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
