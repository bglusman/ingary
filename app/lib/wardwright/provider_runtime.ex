defmodule Wardwright.ProviderRuntime do
  @moduledoc false

  use GenServer

  alias Wardwright.Runtime.Events

  @default_timeout_ms 180_000
  @attempt_count :attempt_count
  @attempt_id_key "attempt_id"
  @attempt_status :status
  @cancelled_count :cancelled_count
  @chunk_count :chunk_count
  @chunk_count_key "chunk_count"
  @completed_count :completed_count
  @configured "configured"
  @consecutive_failures :consecutive_failures
  @consecutive_failures_key "consecutive_failures"
  @created_at_key "created_at"
  @error_count :error_count
  @error_count_key "error_count"
  @health_key "health"
  @kind_key "kind"
  @last_event_at :last_event_at
  @last_event_at_key "last_event_at"
  @last_attempt_at :last_attempt_at
  @last_attempt_at_key "last_attempt_at"
  @last_latency_ms :last_latency_ms
  @last_latency_ms_key "last_latency_ms"
  @last_status :last_status
  @last_status_key "last_status"
  @latency_ms_key "latency_ms"
  @model_key "model"
  @provider_id_key "provider_id"
  @provider_attempts_key "provider_attempts"
  @provider_kind_key "provider_kind"
  @providers_key "providers"
  @provider_timeout_ms_key "provider_timeout_ms"
  @status_key "status"
  @stream_key "stream"
  @started_at :started_at
  @started_at_key "started_at"
  @targets_key "targets"
  @timeout_ms_key "timeout_ms"
  @type_key "type"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, empty_state(), name: __MODULE__)
  end

  def reset do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :reset)
    else
      :ok
    end
  end

  def status do
    state = state_snapshot()

    %{
      @providers_key => providers_status_from_state(state),
      @provider_attempts_key => active_attempts_status_from_state(state)
    }
  end

  def providers_status do
    state_snapshot()
    |> providers_status_from_state()
  end

  def active_attempts_status do
    state_snapshot()
    |> active_attempts_status_from_state()
  end

  defp providers_status_from_state(state) do
    observed = Map.get(state, :stats, %{})

    configured =
      Wardwright.current_config()
      |> Map.get(@targets_key, [])
      |> Enum.map(&provider_status(&1, observed))

    observed_only =
      observed
      |> Enum.reject(fn {_key, stats} ->
        Enum.any?(
          configured,
          &(Map.get(&1, @provider_id_key) == stats.provider_id and
              Map.get(&1, @model_key) == stats.model)
        )
      end)
      |> Enum.map(fn {_key, stats} -> status_record(stats, false) end)

    (configured ++ observed_only)
    |> Enum.sort_by(&{Map.get(&1, @provider_id_key), Map.get(&1, @model_key)})
  end

  defp active_attempts_status_from_state(state) do
    state
    |> Map.get(:active_attempts, %{})
    |> Map.values()
    |> Enum.map(&active_attempt_record/1)
    |> Enum.sort_by(&{Map.get(&1, @started_at_key), Map.get(&1, @attempt_id_key)})
  end

  def complete(target, request, provider_fun)
      when is_map(target) and is_function(provider_fun, 0) do
    run(target, request, provider_fun, false)
  end

  def stream(target, request, provider_fun)
      when is_map(target) and is_function(provider_fun, 0) do
    run(target, request, provider_fun, true)
  end

  def stream_each(target, _request, producer_fun, acc, chunk_fun)
      when is_map(target) and is_function(producer_fun, 1) and is_function(chunk_fun, 2) do
    timeout_ms = target |> timeout_ms() |> normalize_timeout_ms()
    started = System.monotonic_time(:millisecond)
    provider_id = provider_id(target)
    model = Map.get(target, @model_key, "")
    attempt_id = attempt_id(provider_id, model)
    stream_ref = make_ref()
    parent = self()

    publish("provider.attempt.started", %{
      @attempt_id_key => attempt_id,
      @provider_id_key => provider_id,
      @model_key => model,
      @timeout_ms_key => timeout_ms,
      @stream_key => true
    })

    task =
      Task.Supervisor.async_nolink(Wardwright.ProviderRuntime.TaskSupervisor, fn ->
        producer_fun.(fn chunk ->
          send(parent, {stream_ref, :chunk, chunk})
          :ok
        end)
      end)

    {result, acc} =
      await_provider_stream(task, attempt_id, stream_ref, timeout_ms, acc, chunk_fun)

    publish("provider.attempt.finished", %{
      @attempt_id_key => attempt_id,
      @provider_id_key => provider_id,
      @model_key => model,
      @status_key => result_status(result),
      @latency_ms_key => max(0, System.monotonic_time(:millisecond) - started)
    })

    {result, acc}
  end

  defp run(target, request, provider_fun, stream?) do
    timeout_ms = target |> timeout_ms() |> normalize_timeout_ms()
    started = System.monotonic_time(:millisecond)
    provider_id = provider_id(target)
    model = Map.get(target, @model_key, "")
    attempt_id = attempt_id(provider_id, model)

    publish("provider.attempt.started", %{
      @attempt_id_key => attempt_id,
      @provider_id_key => provider_id,
      @model_key => model,
      @timeout_ms_key => timeout_ms,
      @stream_key => stream? or Map.get(request, @stream_key, false) == true
    })

    result =
      Task.Supervisor.async_nolink(Wardwright.ProviderRuntime.TaskSupervisor, provider_fun)
      |> await_provider(timeout_ms)

    publish("provider.attempt.finished", %{
      @attempt_id_key => attempt_id,
      @provider_id_key => provider_id,
      @model_key => model,
      @status_key => result_status(result),
      @latency_ms_key => max(0, System.monotonic_time(:millisecond) - started)
    })

    result
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:reset, _from, _state), do: {:reply, :ok, empty_state()}

  def handle_call(:status, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast({:provider_started, event}, state) do
    {:noreply, record_started(state, event)}
  end

  def handle_cast({:provider_streaming, attempt_id}, state) do
    {:noreply, record_streaming(state, attempt_id)}
  end

  def handle_cast({:provider_cancelling, attempt_id}, state) do
    {:noreply, record_cancelling(state, attempt_id)}
  end

  def handle_cast({:provider_finished, event}, state) do
    {:noreply, record_finished(state, event)}
  end

  defp await_provider(task, timeout_ms) do
    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, "provider task exited: #{inspect(reason)}"}

      nil ->
        {:error, "provider timed out after #{timeout_ms}ms"}
    end
  end

  defp await_provider_stream(task, attempt_id, stream_ref, timeout_ms, acc, chunk_fun) do
    receive do
      {^stream_ref, :chunk, chunk} ->
        record_provider_streaming(attempt_id)

        case chunk_fun.(chunk, acc) do
          {:cont, acc} ->
            await_provider_stream(task, attempt_id, stream_ref, timeout_ms, acc, chunk_fun)

          {:halt, acc} ->
            record_provider_cancelling(attempt_id)
            send(task.pid, {stream_ref, :cancel})

            Task.yield(task, 500) || Task.shutdown(task, :brutal_kill)
            drain_stream_messages(stream_ref, task.ref)

            {{:halted, :cancelled}, acc}
        end

      {ref, result} when ref == task.ref ->
        receive do
          {:DOWN, _ref, :process, _pid, _reason} -> :ok
        after
          0 -> :ok
        end

        drain_stream_messages(stream_ref, task.ref)
        {result, acc}

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        drain_stream_messages(stream_ref, task.ref)
        {{:error, "provider task exited: #{inspect(reason)}"}, acc}
    after
      timeout_ms ->
        result = Task.shutdown(task, :brutal_kill)
        drain_stream_messages(stream_ref, task.ref)

        {normalize_task_result(result) || {:error, "provider timed out after #{timeout_ms}ms"},
         acc}
    end
  end

  defp drain_stream_messages(stream_ref, task_ref) do
    receive do
      {^stream_ref, :chunk, _chunk} ->
        drain_stream_messages(stream_ref, task_ref)

      {^task_ref, _result} ->
        drain_stream_messages(stream_ref, task_ref)

      {:DOWN, ^task_ref, :process, _pid, _reason} ->
        drain_stream_messages(stream_ref, task_ref)
    after
      0 -> :ok
    end
  end

  defp normalize_task_result({:ok, result}), do: result

  defp normalize_task_result({:exit, reason}),
    do: {:error, "provider task exited: #{inspect(reason)}"}

  defp normalize_task_result(nil), do: nil

  defp timeout_ms(target) do
    case integer_value(Map.get(target, @provider_timeout_ms_key)) do
      value when value > 0 -> value
      _ -> @default_timeout_ms
    end
  end

  defp normalize_timeout_ms(value) when is_integer(value) and value > 0, do: value
  defp normalize_timeout_ms(_), do: 180_000

  defp provider_id(target) do
    target
    |> Map.get(@model_key, "")
    |> String.split("/", parts: 2)
    |> List.first()
  end

  defp result_status({:ok, _}), do: "completed"
  defp result_status({:mock, _}), do: "completed"
  defp result_status({:halted, _}), do: "cancelled"
  defp result_status({:error, _}), do: "provider_error"
  defp result_status(_), do: "provider_error"

  defp publish(type, event) do
    event =
      Map.merge(event, %{
        @type_key => type,
        @created_at_key => System.system_time(:second)
      })

    if type == "provider.attempt.started", do: record_provider_started(event)
    if type == "provider.attempt.finished", do: record_provider_finished(event)

    if Process.whereis(Wardwright.PubSub) do
      Events.publish(Events.topic(:models), event)
    end
  end

  defp record_provider_started(event) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:provider_started, event})
    end
  end

  defp record_provider_streaming(attempt_id) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:provider_streaming, attempt_id})
    end
  end

  defp record_provider_cancelling(attempt_id) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:provider_cancelling, attempt_id})
    end
  end

  defp record_provider_finished(event) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:provider_finished, event})
    end
  end

  defp record_finished(state, event) do
    provider_id = Map.get(event, @provider_id_key, "")
    model = Map.get(event, @model_key, "")
    key = {provider_id, model}
    status = Map.get(event, @status_key, "provider_error")
    stats_state = Map.get(state, :stats)
    previous = Map.get(stats_state, key, empty_stats(provider_id, model))
    failed? = status == "provider_error"

    stats =
      previous
      |> Map.update!(@attempt_count, &(&1 + 1))
      |> Map.update!(@completed_count, &(&1 + if(status == "completed", do: 1, else: 0)))
      |> Map.update!(@cancelled_count, &(&1 + if(status == "cancelled", do: 1, else: 0)))
      |> Map.update!(@error_count, &(&1 + if(failed?, do: 1, else: 0)))
      |> Map.put(
        @consecutive_failures,
        if(failed?, do: previous.consecutive_failures + 1, else: 0)
      )
      |> Map.put(@last_status, status)
      |> Map.put(@last_latency_ms, Map.get(event, @latency_ms_key))
      |> Map.put(@last_attempt_at, Map.get(event, @created_at_key, System.system_time(:second)))

    state
    |> Map.put(:stats, Map.put(stats_state, key, stats))
    |> update_in([:active_attempts], &Map.delete(&1, Map.get(event, @attempt_id_key)))
  end

  defp record_started(state, event) do
    attempt_id = Map.get(event, @attempt_id_key)

    if attempt_id in [nil, ""] do
      state
    else
      put_in(
        state,
        [:active_attempts, attempt_id],
        %{
          @attempt_status => "started",
          @chunk_count => 0,
          @last_event_at => Map.get(event, @created_at_key, System.system_time(:second)),
          @started_at => Map.get(event, @created_at_key, System.system_time(:second)),
          attempt_id: attempt_id,
          provider_id: Map.get(event, @provider_id_key, ""),
          model: Map.get(event, @model_key, ""),
          stream: Map.get(event, @stream_key, false) == true,
          timeout_ms: Map.get(event, @timeout_ms_key)
        }
      )
    end
  end

  defp record_streaming(state, attempt_id) do
    update_attempt(state, attempt_id, fn attempt ->
      attempt
      |> Map.put(@attempt_status, "streaming")
      |> Map.put(@last_event_at, System.system_time(:second))
      |> Map.update!(@chunk_count, &(&1 + 1))
    end)
  end

  defp record_cancelling(state, attempt_id) do
    update_attempt(state, attempt_id, fn attempt ->
      attempt
      |> Map.put(@attempt_status, "cancelling")
      |> Map.put(@last_event_at, System.system_time(:second))
    end)
  end

  defp update_attempt(state, attempt_id, fun) do
    update_in(state, [:active_attempts, attempt_id], fn
      nil -> nil
      attempt -> fun.(attempt)
    end)
  end

  defp provider_status(target, observed) do
    provider_id = provider_id(target)
    model = Map.get(target, @model_key, "")
    key = {provider_id, model}

    observed
    |> Map.get(key, empty_stats(provider_id, model))
    |> status_record(true)
    |> Map.put(@kind_key, provider_kind(target))
    |> Map.put(@timeout_ms_key, target |> timeout_ms() |> normalize_timeout_ms())
  end

  defp status_record(stats, configured?) do
    %{
      @provider_id_key => stats.provider_id,
      @model_key => stats.model,
      @configured => configured?,
      @health_key => health(stats),
      "attempt_count" => stats.attempt_count,
      "completed_count" => stats.completed_count,
      "cancelled_count" => stats.cancelled_count,
      @error_count_key => stats.error_count,
      @consecutive_failures_key => stats.consecutive_failures,
      @last_status_key => stats.last_status,
      @last_latency_ms_key => stats.last_latency_ms,
      @last_attempt_at_key => stats.last_attempt_at
    }
  end

  defp active_attempt_record(attempt) do
    %{
      @attempt_id_key => attempt.attempt_id,
      @provider_id_key => attempt.provider_id,
      @model_key => attempt.model,
      @status_key => attempt.status,
      @stream_key => attempt.stream,
      @timeout_ms_key => attempt.timeout_ms,
      @started_at_key => attempt.started_at,
      @last_event_at_key => attempt.last_event_at,
      @chunk_count_key => attempt.chunk_count
    }
  end

  defp health(%{attempt_count: 0}), do: "unknown"
  defp health(%{consecutive_failures: failures}) when failures > 0, do: "degraded"
  defp health(_stats), do: "healthy"

  defp empty_stats(provider_id, model) do
    %{
      provider_id: provider_id,
      model: model,
      attempt_count: 0,
      completed_count: 0,
      cancelled_count: 0,
      error_count: 0,
      consecutive_failures: 0,
      last_status: nil,
      last_latency_ms: nil,
      last_attempt_at: nil
    }
  end

  defp empty_state do
    %{stats: %{}, active_attempts: %{}}
  end

  defp state_snapshot do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :status)
    else
      empty_state()
    end
  end

  defp attempt_id(provider_id, model) do
    id = :erlang.unique_integer([:positive, :monotonic])
    "pat_#{provider_id}_#{:erlang.phash2(model)}_#{id}"
  end

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp integer_value(_), do: nil

  defp provider_kind(target) do
    Map.get(target, @provider_kind_key) || Map.get(target, @kind_key) || provider_id(target)
  end
end
