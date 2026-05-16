defmodule Wardwright.PolicyScenarioStore do
  @moduledoc false

  use Agent

  alias Wardwright.PolicyScenario

  defstruct path: nil, scenarios: %{}

  def start_link(_opts) do
    path = Application.get_env(:wardwright, :policy_scenario_store_path)
    Agent.start_link(fn -> load_state!(path) end, name: __MODULE__)
  end

  def create(pattern_id, attrs) do
    with :ok <- known_pattern(pattern_id),
         {:ok, scenario} <- PolicyScenario.from_map(attrs, pattern_id),
         :ok <- valid_trace_states(pattern_id, scenario) do
      insert(scenario)
    end
  end

  def create_from_receipt(pattern_id, receipt, attrs \\ %{}) do
    with :ok <- known_pattern(pattern_id),
         {:ok, scenario} <- PolicyScenario.from_receipt(receipt, pattern_id, attrs),
         :ok <- valid_trace_states(pattern_id, scenario) do
      insert(scenario)
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
    Agent.get_and_update(__MODULE__, fn %__MODULE__{} = state ->
      updated = %__MODULE__{state | scenarios: %{}}

      case persist(updated) do
        :ok -> {:ok, updated}
        {:error, message} -> {{:error, message}, state}
      end
    end)
  end

  def configure_storage(path) when is_binary(path) or is_nil(path) do
    Agent.get_and_update(__MODULE__, fn state ->
      with {:ok, loaded} <- load_state(path) do
        {{:ok, loaded}, loaded}
      else
        {:error, message} -> {{:error, message}, state}
      end
    end)
  end

  def health do
    Agent.get(__MODULE__, fn state ->
      durable = is_binary(state.path)

      Map.new([
        {"kind", if(durable, do: "file", else: "memory")},
        {"contract_version", "policy-scenario-store-v1"},
        {"read_health", "ok"},
        {"write_health", "ok"},
        {"path", state.path},
        {"scenario_count", map_size(state.scenarios)},
        {"capabilities",
         Map.new([
           {"durable", durable},
           {"atomic_rewrite", durable},
           {"receipt_import", true},
           {"scenario_replay", false}
         ])}
      ])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end)
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
    result =
      Agent.get_and_update(__MODULE__, fn %__MODULE__{} = state ->
        scenarios = Map.put(state.scenarios, key(scenario.pattern_id, scenario.id), scenario)
        updated = %__MODULE__{state | scenarios: scenarios}

        case persist(updated) do
          :ok -> {{:ok, scenario}, updated}
          {:error, message} -> {{:error, message}, state}
        end
      end)

    with {:ok, stored} <- result do
      publish_stored(stored)
    end
  end

  defp publish_stored(scenario) do
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

    {:ok, scenario}
  end

  defp load_state!(path) do
    case load_state(path) do
      {:ok, state} -> state
      {:error, message} -> raise message
    end
  end

  defp load_state(nil), do: {:ok, %__MODULE__{}}

  defp load_state(path) do
    with {:ok, scenarios} <- load_scenarios(path) do
      {:ok, %__MODULE__{path: path, scenarios: scenarios}}
    end
  end

  defp load_scenarios(path) do
    if File.exists?(path) do
      with {:ok, body} <- File.read(path),
           {:ok, decoded} <- Jason.decode(body),
           {:ok, scenarios} <- parse_scenarios(decoded) do
        {:ok, scenarios}
      else
        {:error, %Jason.DecodeError{} = error} -> {:error, Exception.message(error)}
        {:error, reason} when is_atom(reason) -> {:error, :file.format_error(reason)}
        {:error, message} when is_binary(message) -> {:error, message}
        _other -> {:error, "scenario store file must contain a JSON array"}
      end
    else
      {:ok, %{}}
    end
  end

  defp parse_scenarios(decoded) when is_list(decoded) do
    Enum.reduce_while(decoded, {:ok, %{}}, fn attrs, {:ok, scenarios} ->
      with pattern_id when is_binary(pattern_id) <- json_get(attrs, "pattern_id"),
           :ok <- known_pattern(pattern_id),
           {:ok, scenario} <- PolicyScenario.from_map(attrs, pattern_id),
           :ok <- valid_trace_states(pattern_id, scenario) do
        {:cont, {:ok, Map.put(scenarios, key(scenario.pattern_id, scenario.id), scenario)}}
      else
        nil -> {:halt, {:error, "persisted scenario is missing pattern_id"}}
        {:error, message} -> {:halt, {:error, message}}
        _other -> {:halt, {:error, "persisted scenario pattern_id must be a string"}}
      end
    end)
  end

  defp parse_scenarios(_decoded), do: {:error, "scenario store file must contain a JSON array"}

  defp persist(%__MODULE__{path: nil}), do: :ok

  defp persist(%__MODULE__{path: path, scenarios: scenarios}) do
    records =
      scenarios
      |> Map.values()
      |> Enum.sort_by(&{&1.pattern_id, &1.id})
      |> Enum.map(&PolicyScenario.to_map/1)

    tmp_path = "#{path}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, body} <- Jason.encode(records),
         :ok <- File.write(tmp_path, body),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} when is_atom(reason) -> {:error, :file.format_error(reason)}
      {:error, %Jason.EncodeError{} = error} -> {:error, Exception.message(error)}
      {:error, message} when is_binary(message) -> {:error, message}
    end
  end

  defp json_get(map, key) when is_map(map), do: Map.get(map, key)
  defp json_get(_value, _key), do: nil

  defp key(pattern_id, scenario_id), do: {pattern_id, scenario_id}
end
