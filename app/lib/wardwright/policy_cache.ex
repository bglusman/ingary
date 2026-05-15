defmodule Wardwright.PolicyCache do
  @moduledoc false

  use GenServer

  alias Wardwright.PolicyCache.SessionStore

  @catalog :wardwright_policy_cache_catalog
  @anonymous_session "anonymous"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def configure(config) do
    GenServer.call(__MODULE__, {:configure, config || %{}})
  end

  def add(input) when is_map(input) do
    input = normalize_input(input)

    with {:ok, pid} <- store_for(input["scope"]) do
      add_to_store(pid, input)
    end
  end

  def recent(filter \\ %{}, limit \\ nil) do
    filter = normalize_filter(filter || %{})
    limit = normalize_limit(limit, current_config())

    filter
    |> candidate_stores()
    |> Enum.flat_map(fn %{table: table} -> table_events(table) end)
    |> Enum.filter(&matches?(&1, filter))
    |> Enum.sort_by(
      fn event ->
        {event["created_at_unix_ms"], event["sequence"], event["id"]}
      end,
      :desc
    )
    |> Enum.take(limit)
  end

  def count(filter \\ %{}) do
    filter = normalize_filter(filter || %{})

    filter
    |> candidate_stores()
    |> Enum.flat_map(fn %{table: table} -> table_events(table) end)
    |> Enum.count(&matches?(&1, filter))
  end

  def status do
    stores = live_stores()
    config = current_config()
    entry_count = Enum.sum(Enum.map(stores, & &1.entry_count))
    next_sequence = stores |> Enum.map(& &1.next_sequence) |> Enum.max(fn -> 1 end)

    %{
      "kind" => "ets_session_catalog_bounded_history",
      "topology" => "catalog_per_session_tables",
      "max_entries" => config["max_entries"],
      "recent_limit" => config["recent_limit"],
      "entry_count" => entry_count,
      "session_count" => length(stores),
      "next_sequence" => next_sequence,
      "bounded" => true,
      "stores" =>
        Enum.map(stores, fn store ->
          %{
            "scope_key" => store.scope_key,
            "scope" => store.scope,
            "entry_count" => store.entry_count,
            "next_sequence" => store.next_sequence,
            "owner" => inspect(store.pid)
          }
        end)
    }
  end

  def reset, do: configure(%{})

  @impl true
  def init(config) do
    table =
      :ets.new(@catalog, [
        :set,
        :protected,
        :named_table,
        read_concurrency: true
      ])

    {:ok, %{config: normalize_config(config), catalog: table}}
  end

  @impl true
  def handle_call({:configure, config}, _from, state) do
    state.catalog
    |> catalog_entries()
    |> Enum.each(fn %{pid: pid} ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(Wardwright.PolicyCache.SessionSupervisor, pid)
      end
    end)

    :ets.delete_all_objects(state.catalog)
    {:reply, :ok, %{state | config: normalize_config(config)}}
  end

  def handle_call(:config, _from, state) do
    {:reply, state.config, state}
  end

  def handle_call({:ensure_store, scope}, _from, state) do
    scope_key = scope_key(scope)

    case lookup_store(scope_key) do
      {:ok, store} ->
        {:reply, {:ok, store.pid}, state}

      :error ->
        case start_store(scope_key, scope, state.config) do
          {:ok, store} ->
            :ets.insert(state.catalog, {scope_key, store})
            {:reply, {:ok, store.pid}, state}

          {:error, reason} ->
            {:reply, {:error, "failed to start policy cache session store: #{inspect(reason)}"},
             state}
        end
    end
  end

  defp store_for(scope) do
    scope_key = scope_key(scope)

    case lookup_store(scope_key) do
      {:ok, %{pid: pid}} -> {:ok, pid}
      :error -> GenServer.call(__MODULE__, {:ensure_store, scope})
    end
  end

  defp add_to_store(pid, input) do
    SessionStore.add(pid, input)
  catch
    :exit, _reason ->
      with {:ok, fresh_pid} <- GenServer.call(__MODULE__, {:ensure_store, input["scope"]}) do
        SessionStore.add(fresh_pid, input)
      end
  end

  defp start_store(scope_key, scope, config) do
    spec = {SessionStore, scope_key: scope_key, scope: scope, config: config}

    case DynamicSupervisor.start_child(Wardwright.PolicyCache.SessionSupervisor, spec) do
      {:ok, pid} ->
        {:ok, session_store_info(pid)}

      {:error, {:already_started, pid}} ->
        {:ok, session_store_info(pid)}

      other ->
        other
    end
  end

  defp lookup_store(scope_key) do
    case :ets.lookup(@catalog, scope_key) do
      [{^scope_key, %{pid: pid} = store}] when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, store}, else: :error

      _ ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  defp current_config do
    GenServer.call(__MODULE__, :config)
  end

  defp candidate_stores(%{"scope" => scope}) do
    case Map.get(scope, "session_id") do
      value when is_binary(value) and value != "" ->
        case lookup_store(session_scope_key(value)) do
          {:ok, store} -> [store]
          :error -> []
        end

      _ ->
        live_stores()
    end
  end

  defp live_stores do
    @catalog
    |> catalog_entries()
    |> Enum.filter(&Process.alive?(&1.pid))
    |> Enum.map(&refresh_store_info/1)
  rescue
    ArgumentError -> []
  end

  defp refresh_store_info(%{pid: pid} = store) do
    case safe_session_store_info(pid) do
      {:ok, info} -> info
      :error -> store
    end
  end

  defp session_store_info(pid) do
    info = SessionStore.info(pid)

    %{
      pid: info.pid,
      table: info.table,
      scope_key: info.scope_key,
      scope: info.scope,
      entry_count: info.entry_count,
      next_sequence: info.next_sequence
    }
  end

  defp safe_session_store_info(pid) do
    {:ok, session_store_info(pid)}
  catch
    :exit, _ -> :error
  end

  defp catalog_entries(table) do
    table
    |> :ets.tab2list()
    |> Enum.map(fn {_scope_key, store} -> store end)
  end

  defp table_events(table) do
    table
    |> :ets.tab2list()
    |> Enum.map(fn {_sequence, event} -> event end)
  rescue
    ArgumentError -> []
  end

  defp matches?(event, filter) do
    scope = Map.get(filter, "scope", %{})

    (blank?(filter["kind"]) or event["kind"] == filter["kind"]) and
      (blank?(filter["key"]) or event["key"] == filter["key"]) and
      Enum.all?(scope, fn {key, value} -> get_in(event, ["scope", key]) == value end)
  end

  defp normalize_input(input) do
    Map.put(input, "scope", clean_scope(Map.get(input, "scope", %{})))
  end

  defp normalize_filter(filter) do
    filter
    |> stringify_keys()
    |> Map.update("scope", %{}, &clean_scope/1)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_limit(nil, config), do: config["recent_limit"]

  defp normalize_limit(limit, config) do
    limit = positive_integer(limit, config["recent_limit"])
    min(limit, config["recent_limit"])
  end

  defp normalize_config(config) do
    %{
      "max_entries" => positive_integer(config["max_entries"], 64),
      "recent_limit" => positive_integer(config["recent_limit"], 20)
    }
  end

  defp clean_scope(scope) when is_map(scope) do
    scope
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      key = key |> to_string() |> String.trim()
      value = value |> to_string() |> String.trim()

      if key == "" or value == "" do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp clean_scope(_), do: %{}

  defp scope_key(scope) do
    case Map.get(scope, "session_id") do
      value when is_binary(value) and value != "" -> session_scope_key(value)
      _ -> session_scope_key(@anonymous_session)
    end
  end

  defp session_scope_key(session_id), do: "session:" <> session_id

  defp blank?(value), do: value in [nil, ""]

  defp positive_integer(value, default) do
    case integer_value(value) do
      value when value > 0 -> value
      _ -> default
    end
  end

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  defp integer_value(_), do: 0
end
