defmodule Wardwright.Runtime do
  @moduledoc false

  alias Wardwright.Runtime.{ModelRuntime, SessionRuntime}

  @anonymous_session "anonymous"

  def ensure_model(model_id, version) do
    case Registry.lookup(Wardwright.Runtime.Registry, {:model, model_id, version}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        spec = {ModelRuntime, model_id: model_id, version: version}

        case DynamicSupervisor.start_child(Wardwright.Runtime.ModelSupervisor, spec) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          {:error, {:shutdown, {:failed_to_start_child, _id, {:already_started, pid}}}} ->
            {:ok, pid}

          other ->
            other
        end
    end
  end

  def ensure_session(model_id, version, session_id) do
    session_id = normalize_session_id(session_id)

    with {:ok, _model_pid} <- ensure_model(model_id, version) do
      case Registry.lookup(
             Wardwright.Runtime.Registry,
             {:session, model_id, version, session_id}
           ) do
        [{pid, _}] ->
          {:ok, pid}

        [] ->
          spec = {SessionRuntime, model_id: model_id, version: version, session_id: session_id}

          case DynamicSupervisor.start_child(Wardwright.Runtime.SessionSupervisor, spec) do
            {:ok, pid} ->
              {:ok, pid}

            {:error, {:already_started, pid}} ->
              {:ok, pid}

            {:error, {:shutdown, {:failed_to_start_child, _id, {:already_started, pid}}}} ->
              {:ok, pid}

            other ->
              other
          end
      end
    end
  end

  def record_session_event(model_id, version, session_id, type, fields \\ %{}) do
    with {:ok, pid} <- ensure_session(model_id, version, session_id) do
      {:ok, SessionRuntime.record(pid, type, fields)}
    end
  end

  def status do
    %{
      "models" =>
        Wardwright.Runtime.Registry
        |> Registry.select([
          {{{:"$1", :"$2", :"$3"}, :"$4", :_}, [{:==, :"$1", :model}], [{{:"$2", :"$3", :"$4"}}]}
        ])
        |> Enum.map(fn {_model_id, _version, pid} -> ModelRuntime.status(pid) end)
        |> Enum.sort_by(&{&1["model_id"], &1["version"]}),
      "sessions" =>
        Wardwright.Runtime.Registry
        |> Registry.select([
          {{{:"$1", :"$2", :"$3", :"$4"}, :"$5", :_}, [{:==, :"$1", :session}],
           [{{:"$2", :"$3", :"$4", :"$5"}}]}
        ])
        |> Enum.map(fn {_model_id, _version, _session_id, pid} -> SessionRuntime.status(pid) end)
        |> Enum.sort_by(&{&1["model_id"], &1["version"], &1["session_id"]})
    }
  end

  def normalize_session_id(nil), do: @anonymous_session
  def normalize_session_id(""), do: @anonymous_session

  def normalize_session_id(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> @anonymous_session
      session_id -> session_id
    end
  end
end
