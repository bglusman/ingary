defmodule ElixirIngary.Runtime.SessionRuntime do
  @moduledoc false

  use GenServer

  alias ElixirIngary.Runtime.Events

  def start_link(opts) do
    model_id = Keyword.fetch!(opts, :model_id)
    version = Keyword.fetch!(opts, :version)
    session_id = Keyword.fetch!(opts, :session_id)

    GenServer.start_link(__MODULE__, {model_id, version, session_id},
      name: via(model_id, version, session_id)
    )
  end

  def child_spec(opts) do
    model_id = Keyword.fetch!(opts, :model_id)
    version = Keyword.fetch!(opts, :version)
    session_id = Keyword.fetch!(opts, :session_id)

    %{
      id: {__MODULE__, model_id, version, session_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  def via(model_id, version, session_id) do
    {:via, Registry, {ElixirIngary.Runtime.Registry, {:session, model_id, version, session_id}}}
  end

  def record(pid, type, fields \\ %{}) when is_pid(pid) and is_binary(type) and is_map(fields) do
    GenServer.call(pid, {:record, type, fields})
  end

  def status(pid), do: GenServer.call(pid, :status)

  @impl true
  def init({model_id, version, session_id}) do
    state = %{
      model_id: model_id,
      version: version,
      session_id: session_id,
      sequence: 0,
      event_count: 0,
      started_at: System.system_time(:second),
      last_event: nil
    }

    {:ok, state, {:continue, :publish_started}}
  end

  @impl true
  def handle_continue(:publish_started, state) do
    {:noreply, publish(state, "session.started", %{})}
  end

  @impl true
  def handle_call({:record, type, fields}, _from, state) do
    state = publish(state, type, fields)
    {:reply, state.last_event, state}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       "model_id" => state.model_id,
       "version" => state.version,
       "session_id" => state.session_id,
       "pid" => inspect(self()),
       "started_at" => state.started_at,
       "event_count" => state.event_count,
       "last_event" => state.last_event
     }, state}
  end

  defp publish(state, type, fields) do
    sequence = state.sequence + 1

    event =
      fields
      |> stringify_keys()
      |> Map.merge(%{
        "type" => type,
        "model_id" => state.model_id,
        "version" => state.version,
        "session_id" => state.session_id,
        "sequence" => sequence,
        "created_at" => System.system_time(:second)
      })

    topics = [
      Events.topic(:models),
      Events.topic(:model, state.model_id, state.version),
      Events.topic(:session, state.model_id, state.version, state.session_id)
    ]

    Events.publish_many(topics, event)

    %{state | sequence: sequence, event_count: state.event_count + 1, last_event: event}
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
