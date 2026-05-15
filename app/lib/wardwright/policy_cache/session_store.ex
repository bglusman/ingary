defmodule Wardwright.PolicyCache.SessionStore do
  @moduledoc false

  use GenServer

  alias Wardwright.Runtime.Events

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def child_spec(opts) do
    scope_key = Keyword.fetch!(opts, :scope_key)

    %{
      id: {__MODULE__, scope_key},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  def add(pid, input) when is_pid(pid) and is_map(input) do
    GenServer.call(pid, {:add, input})
  end

  def configure(pid, config) when is_pid(pid) do
    GenServer.call(pid, {:configure, config})
  end

  def info(pid) when is_pid(pid), do: GenServer.call(pid, :info)

  @impl true
  def init(opts) do
    table =
      :ets.new(:wardwright_policy_cache_session, [
        :ordered_set,
        :protected,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok,
     %{
       table: table,
       scope_key: Keyword.fetch!(opts, :scope_key),
       scope: Keyword.get(opts, :scope, %{}),
       config: Keyword.fetch!(opts, :config),
       next: 0
     }}
  end

  @impl true
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

  def handle_call({:configure, config}, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, %{state | config: config, next: 0}}
  end

  def handle_call(:info, _from, state) do
    {:reply,
     %{
       pid: self(),
       table: state.table,
       scope_key: state.scope_key,
       scope: state.scope,
       entry_count: table_size(state.table),
       next_sequence: state.next + 1
     }, state}
  end

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
           "id" =>
             "pc_" <>
               short_scope_id(state.scope_key) <>
               "_" <>
               String.pad_leading(Integer.to_string(sequence, 16), 16, "0"),
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
    excess = table_size(table) - config["max_entries"]

    if excess > 0 do
      table
      |> events()
      |> Enum.sort_by(fn event -> {event["created_at_unix_ms"], event["sequence"]} end)
      |> Enum.take(excess)
      |> Enum.each(fn event -> :ets.delete(table, event["sequence"]) end)
    end
  end

  defp publish_added(event, state) do
    if Process.whereis(Wardwright.PubSub) do
      Events.publish(Events.topic(:policies), %{
        "type" => "policy_cache.event_recorded",
        "sequence" => event["sequence"],
        "kind" => event["kind"],
        "key" => event["key"],
        "scope" => event["scope"],
        "scope_key" => state.scope_key,
        "created_at_unix_ms" => event["created_at_unix_ms"],
        "entry_count" => table_size(state.table),
        "max_entries" => state.config["max_entries"]
      })
    end
  end

  defp events(table) do
    table
    |> :ets.tab2list()
    |> Enum.map(fn {_sequence, event} -> event end)
  end

  defp table_size(table), do: :ets.info(table, :size) || 0

  defp short_scope_id(scope_key) do
    :crypto.hash(:sha256, scope_key)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
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

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  defp integer_value(_), do: 0
end
