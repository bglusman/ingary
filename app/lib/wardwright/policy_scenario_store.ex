defmodule Wardwright.PolicyScenarioStore do
  @moduledoc false

  use Agent

  alias Wardwright.PolicyScenario

  def start_link(_opts) do
    Agent.start_link(fn -> %{scenarios: %{}} end, name: __MODULE__)
  end

  def create(pattern_id, attrs) do
    with :ok <- known_pattern(pattern_id),
         {:ok, scenario} <- PolicyScenario.from_map(attrs, pattern_id),
         :ok <- valid_trace_states(pattern_id, scenario) do
      {:ok, insert(scenario)}
    end
  end

  def list(pattern_id) do
    Agent.get(__MODULE__, fn state ->
      state.scenarios
      |> Map.values()
      |> Enum.filter(&(&1.pattern_id == pattern_id))
      |> Enum.sort_by(&{&1.created_at, &1.id})
    end)
  end

  def get(pattern_id, scenario_id) do
    Agent.get(__MODULE__, fn state ->
      Map.get(state.scenarios, key(pattern_id, scenario_id))
    end)
  end

  def clear do
    Agent.update(__MODULE__, fn _state -> %{scenarios: %{}} end)
  end

  defp known_pattern(pattern_id) do
    if pattern_id in Wardwright.PolicyProjection.pattern_ids() do
      :ok
    else
      {:error, "unknown policy pattern #{pattern_id}"}
    end
  end

  defp valid_trace_states(pattern_id, scenario) do
    state_ids = Wardwright.PolicyProjection.state_ids(pattern_id) |> MapSet.new()

    scenario
    |> PolicyScenario.trace_state_ids()
    |> Enum.find(&(not MapSet.member?(state_ids, &1)))
    |> case do
      nil -> :ok
      state_id -> {:error, "trace state_id #{state_id} is not valid for pattern #{pattern_id}"}
    end
  end

  defp insert(%PolicyScenario{} = scenario) do
    Agent.update(__MODULE__, fn state ->
      put_in(state, [:scenarios, key(scenario.pattern_id, scenario.id)], scenario)
    end)

    Wardwright.Runtime.Events.publish(
      Wardwright.Runtime.Events.topic(:simulations),
      Map.new([
        {"type", "policy_scenario.stored"},
        {"pattern_id", scenario.pattern_id},
        {"scenario_id", scenario.id},
        {"source", scenario.source},
        {"pinned", scenario.pinned}
      ])
    )

    scenario
  end

  defp key(pattern_id, scenario_id), do: {pattern_id, scenario_id}
end
