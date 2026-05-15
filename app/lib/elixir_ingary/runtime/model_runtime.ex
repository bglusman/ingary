defmodule ElixirIngary.Runtime.ModelRuntime do
  @moduledoc false

  use GenServer

  alias ElixirIngary.Runtime.Events

  def start_link(opts) do
    model_id = Keyword.fetch!(opts, :model_id)
    version = Keyword.fetch!(opts, :version)

    GenServer.start_link(__MODULE__, {model_id, version}, name: via(model_id, version))
  end

  def child_spec(opts) do
    model_id = Keyword.fetch!(opts, :model_id)
    version = Keyword.fetch!(opts, :version)

    %{
      id: {__MODULE__, model_id, version},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  def via(model_id, version),
    do: {:via, Registry, {ElixirIngary.Runtime.Registry, {:model, model_id, version}}}

  def status(pid), do: GenServer.call(pid, :status)

  @impl true
  def init({model_id, version}) do
    state = %{
      model_id: model_id,
      version: version,
      started_at: System.system_time(:second)
    }

    event = %{
      "type" => "model.started",
      "model_id" => model_id,
      "version" => version,
      "started_at" => state.started_at
    }

    Events.publish_many([Events.topic(:models), Events.topic(:model, model_id, version)], event)

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       "model_id" => state.model_id,
       "version" => state.version,
       "pid" => inspect(self()),
       "started_at" => state.started_at
     }, state}
  end
end
