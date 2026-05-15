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
