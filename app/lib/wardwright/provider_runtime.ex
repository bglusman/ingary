defmodule Wardwright.ProviderRuntime do
  @moduledoc false

  use GenServer

  alias Wardwright.Runtime.Events

  @default_timeout_ms 180_000
  @attempt_count :attempt_count
  @cancelled_count :cancelled_count
  @completed_count :completed_count
  @configured "configured"
  @consecutive_failures :consecutive_failures
  @consecutive_failures_key "consecutive_failures"
  @created_at_key "created_at"
  @error_count :error_count
  @error_count_key "error_count"
  @health_key "health"
  @kind_key "kind"
  @last_attempt_at :last_attempt_at
  @last_attempt_at_key "last_attempt_at"
  @last_latency_ms :last_latency_ms
  @last_latency_ms_key "last_latency_ms"
  @last_status :last_status
  @last_status_key "last_status"
  @latency_ms_key "latency_ms"
  @model_key "model"
  @provider_id_key "provider_id"
  @provider_kind_key "provider_kind"
  @providers_key "providers"
  @provider_timeout_ms_key "provider_timeout_ms"
  @status_key "status"
  @stream_key "stream"
  @targets_key "targets"
  @timeout_ms_key "timeout_ms"
  @type_key "type"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def reset do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :reset)
    else
      :ok
    end
  end

  def status do
    %{@providers_key => providers_status()}
  end

  def providers_status do
    observed =
      if Process.whereis(__MODULE__) do
        GenServer.call(__MODULE__, :status)
      else
        %{}
      end

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
    stream_ref = make_ref()
    parent = self()

    publish("provider.attempt.started", %{
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

    {result, acc} = await_provider_stream(task, stream_ref, timeout_ms, acc, chunk_fun)

    publish("provider.attempt.finished", %{
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

    publish("provider.attempt.started", %{
      @provider_id_key => provider_id,
      @model_key => model,
      @timeout_ms_key => timeout_ms,
      @stream_key => stream? or Map.get(request, @stream_key, false) == true
    })

    result =
      Task.Supervisor.async_nolink(Wardwright.ProviderRuntime.TaskSupervisor, provider_fun)
      |> await_provider(timeout_ms)

    publish("provider.attempt.finished", %{
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
  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{}}

  def handle_call(:status, _from, state), do: {:reply, state, state}

  @impl true
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

  defp await_provider_stream(task, stream_ref, timeout_ms, acc, chunk_fun) do
    receive do
      {^stream_ref, :chunk, chunk} ->
        case chunk_fun.(chunk, acc) do
          {:cont, acc} ->
            await_provider_stream(task, stream_ref, timeout_ms, acc, chunk_fun)

          {:halt, acc} ->
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

    if type == "provider.attempt.finished", do: record_provider_finished(event)

    if Process.whereis(Wardwright.PubSub) do
      Events.publish(Events.topic(:models), event)
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
    previous = Map.get(state, key, empty_stats(provider_id, model))
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

    Map.put(state, key, stats)
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
