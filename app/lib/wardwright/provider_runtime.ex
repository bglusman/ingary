defmodule Wardwright.ProviderRuntime do
  @moduledoc false

  alias Wardwright.Runtime.Events

  @default_timeout_ms 180_000

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
    model = Map.get(target, "model", "")
    stream_ref = make_ref()
    parent = self()

    publish("provider.attempt.started", %{
      "provider_id" => provider_id,
      "model" => model,
      "timeout_ms" => timeout_ms,
      "stream" => true
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
      "provider_id" => provider_id,
      "model" => model,
      "status" => result_status(result),
      "latency_ms" => max(0, System.monotonic_time(:millisecond) - started)
    })

    {result, acc}
  end

  defp run(target, request, provider_fun, stream?) do
    timeout_ms = target |> timeout_ms() |> normalize_timeout_ms()
    started = System.monotonic_time(:millisecond)
    provider_id = provider_id(target)
    model = Map.get(target, "model", "")

    publish("provider.attempt.started", %{
      "provider_id" => provider_id,
      "model" => model,
      "timeout_ms" => timeout_ms,
      "stream" => stream? or Map.get(request, "stream", false) == true
    })

    result =
      Task.Supervisor.async_nolink(Wardwright.ProviderRuntime.TaskSupervisor, provider_fun)
      |> await_provider(timeout_ms)

    publish("provider.attempt.finished", %{
      "provider_id" => provider_id,
      "model" => model,
      "status" => result_status(result),
      "latency_ms" => max(0, System.monotonic_time(:millisecond) - started)
    })

    result
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

            {{:halted, :cancelled}, acc}
        end

      {ref, result} when ref == task.ref ->
        receive do
          {:DOWN, _ref, :process, _pid, _reason} -> :ok
        after
          0 -> :ok
        end

        {result, acc}

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        {{:error, "provider task exited: #{inspect(reason)}"}, acc}
    after
      timeout_ms ->
        result = Task.shutdown(task, :brutal_kill)

        {normalize_task_result(result) || {:error, "provider timed out after #{timeout_ms}ms"},
         acc}
    end
  end

  defp normalize_task_result({:ok, result}), do: result

  defp normalize_task_result({:exit, reason}),
    do: {:error, "provider task exited: #{inspect(reason)}"}

  defp normalize_task_result(nil), do: nil

  defp timeout_ms(target) do
    case integer_value(Map.get(target, "provider_timeout_ms")) do
      value when value > 0 -> value
      _ -> @default_timeout_ms
    end
  end

  defp normalize_timeout_ms(value) when is_integer(value) and value > 0, do: value
  defp normalize_timeout_ms(_), do: 180_000

  defp provider_id(target) do
    target
    |> Map.get("model", "")
    |> String.split("/", parts: 2)
    |> List.first()
  end

  defp result_status({:ok, _}), do: "completed"
  defp result_status({:mock, _}), do: "completed"
  defp result_status({:halted, _}), do: "cancelled"
  defp result_status({:error, _}), do: "provider_error"
  defp result_status(_), do: "provider_error"

  defp publish(type, event) do
    if Process.whereis(Wardwright.PubSub) do
      Events.publish(
        Events.topic(:models),
        Map.merge(event, %{
          "type" => type,
          "created_at" => System.system_time(:second)
        })
      )
    end
  end

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp integer_value(_), do: nil
end
