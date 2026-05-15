defmodule Wardwright.PolicyCache do
  @moduledoc false

  use GenServer

  @table :wardwright_policy_cache

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def configure(config) do
    GenServer.call(__MODULE__, {:configure, config || %{}})
  end

  def add(input) when is_map(input) do
    GenServer.call(__MODULE__, {:add, input})
  end

  def recent(filter \\ %{}, limit \\ nil) do
    GenServer.call(__MODULE__, {:recent, filter || %{}, limit})
  end

  def count(filter \\ %{}) do
    GenServer.call(__MODULE__, {:count, filter || %{}})
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  def reset, do: configure(%{})

  @impl true
  def init(config) do
    table =
      :ets.new(@table, [
        :ordered_set,
        :protected,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{config: normalize_config(config), next: 0, table: table}}
  end

  @impl true
  def handle_call({:configure, config}, _from, state) do
    :ets.delete_all_objects(state.table)
    state = %{state | config: normalize_config(config), next: 0}
    {:reply, :ok, state}
  end

  def handle_call({:add, input}, _from, state) do
    with {:ok, event} <- build_event(input, state) do
      :ets.insert(state.table, {event["sequence"], event})
      evict(state.table, state.config)
      state = %{state | next: state.next + 1}
      publish_added(event, state)
      {:reply, {:ok, event}, state}
    else
      {:error, message} ->
        {:reply, {:error, message}, state}
    end
  end

  def handle_call({:recent, filter, limit}, _from, state) do
    limit = normalize_limit(limit, state.config)

    events =
      state.table
      |> events()
      |> Enum.sort_by(& &1["sequence"], :desc)
      |> Enum.filter(&matches?(&1, filter))
      |> Enum.take(limit)

    {:reply, events, state}
  end

  def handle_call({:count, filter}, _from, state) do
    count =
      state.table
      |> events()
      |> Enum.count(&matches?(&1, filter))

    {:reply, count, state}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       "kind" => "ets_bounded_recent_history",
       "max_entries" => state.config["max_entries"],
       "recent_limit" => state.config["recent_limit"],
       "entry_count" => :ets.info(state.table, :size) || 0,
       "next_sequence" => state.next + 1,
       "bounded" => true
     }, state}
  end

  defp initial_event_count(table), do: :ets.info(table, :size) || 0

  defp build_event(input, state) do
    kind = input |> Map.get("kind", "") |> to_string() |> String.trim()
    key = input |> Map.get("key", "") |> to_string() |> String.trim()
    created_at = integer_value(Map.get(input, "created_at_unix_ms", 0))

    cond do
      kind == "" ->
        {:error, "kind must not be empty"}

      created_at < 0 ->
        {:error, "created_at_unix_ms must not be negative"}

      state.config["max_entries"] < 1 ->
        {:error, "policy cache is disabled"}

      true ->
        sequence = state.next + 1

        {:ok,
         %{
           "id" => "pc_" <> String.pad_leading(Integer.to_string(sequence, 16), 16, "0"),
           "sequence" => sequence,
           "kind" => kind,
           "key" => key,
           "scope" => clean_scope(Map.get(input, "scope", %{})),
           "value" => Map.get(input, "value", %{}),
           "created_at_unix_ms" => created_at
         }}
    end
  end

  defp evict(table, config) do
    excess = initial_event_count(table) - config["max_entries"]

    if excess > 0 do
      table
      |> events()
      |> Enum.sort_by(fn event -> {event["created_at_unix_ms"], event["sequence"]} end)
      |> Enum.take(excess)
      |> Enum.each(fn event -> :ets.delete(table, event["sequence"]) end)
    end
  end

  defp events(table) do
    table
    |> :ets.tab2list()
    |> Enum.map(fn {_sequence, event} -> event end)
  end

  defp publish_added(event, state) do
    if Process.whereis(Wardwright.PubSub) do
      Wardwright.Runtime.Events.publish(Wardwright.Runtime.Events.topic(:policies), %{
        "type" => "policy_cache.event_recorded",
        "sequence" => event["sequence"],
        "kind" => event["kind"],
        "key" => event["key"],
        "scope" => event["scope"],
        "created_at_unix_ms" => event["created_at_unix_ms"],
        "entry_count" => initial_event_count(state.table),
        "max_entries" => state.config["max_entries"]
      })
    end
  end

  defp matches?(event, filter) do
    scope = Map.get(filter, "scope", %{})

    (blank?(filter["kind"]) or event["kind"] == filter["kind"]) and
      (blank?(filter["key"]) or event["key"] == filter["key"]) and
      Enum.all?(scope, fn {key, value} -> get_in(event, ["scope", key]) == value end)
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
