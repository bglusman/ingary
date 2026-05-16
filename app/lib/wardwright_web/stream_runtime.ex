defmodule WardwrightWeb.StreamRuntime do
  @moduledoc false

  import Plug.Conn

  alias WardwrightWeb.ReceiptBuilder
  alias WardwrightWeb.RequestContext

  def run(conn, model, caller, request, decision, policy) do
    receipt = ReceiptBuilder.build("completed", model, caller, request, decision, false, policy)
    receipt_id = receipt["receipt_id"]
    rules = Wardwright.current_config()["stream_rules"] || []

    acc = %{
      conn:
        conn
        |> put_resp_header("x-wardwright-receipt-id", receipt_id)
        |> put_resp_header("x-wardwright-selected-model", decision.selected_model),
      sent?: false,
      request: request,
      receipt_id: receipt_id,
      chunks: []
    }

    {stream_policy, provider, acc} =
      run_stream_runtime_attempt(request, decision, rules, 0, 0, 0, [], [], acc)

    provider =
      provider
      |> Map.put(:stream_policy, stream_policy)
      |> Map.put(:stream_chunks, stream_policy.chunks)
      |> Map.put(:content, released_content(acc))
      |> Map.put_new(:structured_output, nil)

    Wardwright.Policy.History.record_response(caller, provider.content)

    receipt = ReceiptBuilder.apply_provider_outcome(receipt, provider)
    Wardwright.ReceiptStore.insert(receipt)

    record_runtime_event(model, caller, "receipt.finalized", %{
      "receipt_id" => receipt["receipt_id"],
      "status" => get_in(receipt, ["final", "status"]),
      "simulation" => false,
      "alert_count" => get_in(receipt, ["final", "alert_count"]) || 0
    })

    if acc.sent? do
      acc.conn
    else
      json(
        acc.conn,
        ReceiptBuilder.response_status(receipt),
        ReceiptBuilder.chat_response(request, receipt, decision, provider.content)
      )
    end
  end

  defp run_stream_runtime_attempt(
         request,
         decision,
         rules,
         active_retry_budget,
         attempt_index,
         retry_count,
         events,
         attempts,
         acc
       ) do
    stream_acc =
      Map.merge(acc, %{
        policy: Wardwright.Policy.Stream.start(rules, attempt_index: attempt_index)
      })

    {provider, stream_acc} =
      stream_attempt_each(request, decision, attempt_index, stream_acc, &stream_runtime_chunk/2)

    provider = Map.put(provider, :selected_model, decision.selected_model)

    {policy, stream_acc} =
      if provider.status == "completed" and stream_acc.policy.status == "completed" do
        {policy, released_chunks} = Wardwright.Policy.Stream.finish(stream_acc.policy)

        released_chunks =
          if is_nil(policy.horizon_bytes), do: policy.chunks, else: released_chunks

        stream_acc = release_stream_chunks(stream_acc, released_chunks)
        {policy, stream_acc}
      else
        {stream_acc.policy, stream_acc}
      end

    attempt = stream_attempt(policy, attempt_index, provider)
    events = events ++ policy.events
    attempts = attempts ++ [attempt]
    trigger_event = List.last(policy.events) || %{}
    retry_budget = stream_retry_budget(trigger_event, active_retry_budget)

    cond do
      provider.status == "provider_error" ->
        policy =
          provider_error_stream_policy(
            provider,
            retry_count,
            retry_budget,
            Enum.drop(attempts, -1)
          )

        stream_acc =
          if stream_acc.sent? do
            send_stream_policy_terminal(stream_acc, policy)
          else
            stream_acc
          end

        {policy, provider, stream_acc}

      policy.status == "stream_policy_retry_required" and
        retry_count < retry_budget and not stream_acc.sent? ->
        {retry_request, reminder_injected?} = stream_retry_request(request, trigger_event)

        case stream_retry_decision(decision, retry_request) do
          {:ok, retry_decision, route_event} ->
            retry_event = %{
              "type" => "attempt.retry_requested",
              "attempt_index" => attempt_index,
              "next_attempt_index" => attempt_index + 1,
              "retry_count" => retry_count + 1,
              "max_retries" => retry_budget,
              "rule_id" => Map.get(trigger_event, "rule_id"),
              "reminder" => Map.get(trigger_event, "reminder"),
              "reminder_injected" => reminder_injected?,
              "selected_model" => retry_decision.selected_model
            }

            retry_events =
              [ReceiptBuilder.reject_blank(retry_event), route_event]
              |> Enum.reject(&is_nil/1)

            run_stream_runtime_attempt(
              retry_request,
              retry_decision,
              rules,
              retry_budget,
              attempt_index + 1,
              retry_count + 1,
              events ++ retry_events,
              attempts,
              %{
                stream_acc
                | conn:
                    put_resp_header(
                      stream_acc.conn,
                      "x-wardwright-selected-model",
                      retry_decision.selected_model
                    ),
                  sent?: false,
                  chunks: acc.chunks
              }
            )

          {:error, fit_error} ->
            context_event =
              %{
                "type" => "attempt.retry_context_exceeded",
                "attempt_index" => attempt_index,
                "next_attempt_index" => attempt_index + 1,
                "retry_count" => retry_count,
                "max_retries" => retry_budget,
                "rule_id" => Map.get(trigger_event, "rule_id"),
                "reminder" => Map.get(trigger_event, "reminder"),
                "reminder_injected" => reminder_injected?
              }
              |> Map.merge(fit_error)
              |> ReceiptBuilder.reject_blank()

            policy =
              policy
              |> Map.put(:status, "stream_policy_retry_context_exceeded")
              |> Map.put(:events, events ++ [context_event])
              |> Map.put(:attempts, attempts)
              |> Map.put(:retry_count, retry_count)
              |> Map.put(:max_retries, retry_budget)
              |> Map.put(:called_provider, provider.called_provider)
              |> Map.put(:mock, provider.mock)
              |> Map.put(:provider_latency_ms, stream_latency_ms(attempts))

            {policy, %{provider | status: policy.status, content: nil}, stream_acc}
        end

      policy.status == "stream_policy_retry_required" and stream_acc.sent? ->
        skip_event =
          %{
            "type" => "attempt.retry_skipped_after_release",
            "attempt_index" => attempt_index,
            "retry_count" => retry_count,
            "max_retries" => retry_budget,
            "rule_id" => Map.get(trigger_event, "rule_id"),
            "reason" => "response_already_started",
            "released_bytes" => policy.released_bytes
          }
          |> ReceiptBuilder.reject_blank()

        policy =
          policy
          |> Map.put(:status, "stream_policy_retry_skipped_after_release")
          |> Map.update!(:events, &(&1 ++ [skip_event]))

        stream_acc = send_stream_policy_terminal(stream_acc, policy)

        policy =
          policy
          |> Map.put(:events, events ++ [skip_event])
          |> Map.put(:attempts, attempts)
          |> Map.put(:retry_count, retry_count)
          |> Map.put(:max_retries, retry_budget)
          |> Map.put(:called_provider, provider.called_provider)
          |> Map.put(:mock, provider.mock)
          |> Map.put(:provider_latency_ms, stream_latency_ms(attempts))

        {policy, %{provider | status: policy.status, content: released_content(stream_acc)},
         stream_acc}

      policy.status != "completed" and stream_acc.sent? ->
        stream_acc = send_stream_policy_terminal(stream_acc, policy)

        policy =
          policy
          |> Map.put(:events, events)
          |> Map.put(:attempts, attempts)
          |> Map.put(:retry_count, retry_count)
          |> Map.put(:max_retries, retry_budget)
          |> Map.put(:called_provider, provider.called_provider)
          |> Map.put(:mock, provider.mock)
          |> Map.put(:provider_latency_ms, stream_latency_ms(attempts))

        {policy, %{provider | status: policy.status, content: released_content(stream_acc)},
         stream_acc}

      true ->
        stream_acc = maybe_finish_sse(stream_acc)

        provider =
          if policy.status == "completed", do: provider, else: %{provider | status: policy.status}

        policy =
          policy
          |> Map.put(:events, events)
          |> Map.put(:attempts, attempts)
          |> Map.put(:retry_count, retry_count)
          |> Map.put(:max_retries, retry_budget)
          |> Map.put(:called_provider, provider.called_provider)
          |> Map.put(:mock, provider.mock)
          |> Map.put(:provider_latency_ms, stream_latency_ms(attempts))

        {policy, provider, stream_acc}
    end
  end

  defp stream_retry_fit_error(decision, request) do
    selected_model = Map.get(decision, :selected_model)
    estimated = Wardwright.estimate_prompt_tokens(Map.get(request, "messages", []))
    context_window = Map.get(decision, :selected_context_window)

    if is_integer(context_window) and context_window < estimated do
      %{
        "selected_model" => selected_model,
        "reason" => "context_window_too_small",
        "context_window" => context_window,
        "estimated_prompt_tokens" => estimated
      }
    end
  end

  defp stream_retry_decision(decision, request) do
    case stream_retry_fit_error(decision, request) do
      nil ->
        {:ok, decision, nil}

      fit_error ->
        estimated = Wardwright.estimate_prompt_tokens(Map.get(request, "messages", []))
        attrs = Map.get(decision, :policy_route_constraints, %{})
        retry_decision = Wardwright.select_route(estimated, attrs)

        cond do
          retry_decision.route_blocked ->
            {:error, fit_error}

          retry_decision.selected_model == decision.selected_model ->
            {:error, fit_error}

          is_integer(retry_decision.selected_context_window) and
              retry_decision.selected_context_window >= estimated ->
            {:ok, retry_decision, stream_retry_reroute_event(decision, retry_decision, estimated)}

          true ->
            {:error, fit_error}
        end
    end
  end

  defp stream_retry_reroute_event(previous_decision, retry_decision, estimated) do
    %{
      "type" => "attempt.retry_rerouted",
      "reason" => "retry_prompt_exceeded_selected_context",
      "from_selected_model" => previous_decision.selected_model,
      "from_context_window" => previous_decision.selected_context_window,
      "selected_model" => retry_decision.selected_model,
      "context_window" => retry_decision.selected_context_window,
      "estimated_prompt_tokens" => estimated,
      "route_type" => retry_decision.route_type,
      "fallback_used" => retry_decision.fallback_used
    }
    |> ReceiptBuilder.reject_blank()
  end

  defp stream_attempt_each(request, decision, attempt_index, acc, chunk_fun) do
    mock_chunks =
      if allow_mock_stream_chunks?() do
        attempt_chunks = get_in(request, ["metadata", "mock_stream_attempt_chunks"])

        cond do
          is_list(attempt_chunks) and is_list(Enum.at(attempt_chunks, attempt_index)) ->
            Enum.at(attempt_chunks, attempt_index)

          attempt_index == 0 ->
            get_in(request, ["metadata", "mock_stream_chunks"])

          true ->
            nil
        end
      end

    case mock_chunks do
      chunks when is_list(chunks) and chunks != [] ->
        Enum.reduce_while(Enum.map(chunks, &RequestContext.metadata_string/1), acc, fn chunk,
                                                                                       acc ->
          case chunk_fun.(chunk, acc) do
            {:cont, acc} -> {:cont, acc}
            {:halt, acc} -> {:halt, acc}
          end
        end)
        |> then(fn acc ->
          {%{
             content: nil,
             status: "completed",
             latency_ms: 0,
             error: nil,
             called_provider: false,
             mock: true
           }, acc}
        end)

      _ ->
        stream_request = Map.put(request, "wardwright_attempt_index", attempt_index)

        Wardwright.stream_selected_model_each(
          decision.selected_model,
          stream_request,
          acc,
          chunk_fun
        )
    end
  end

  defp stream_runtime_chunk(chunk, acc) do
    case Wardwright.Policy.Stream.consume(acc.policy, chunk) do
      {:cont, policy, released_chunks} ->
        released_chunks = if is_nil(policy.horizon_bytes), do: [], else: released_chunks

        {:cont,
         acc
         |> Map.put(:policy, policy)
         |> release_stream_chunks(released_chunks)}

      {:halt, policy, released_chunks} ->
        released_chunks = if is_nil(policy.horizon_bytes), do: [], else: released_chunks

        {:halt,
         acc
         |> Map.put(:policy, policy)
         |> release_stream_chunks(released_chunks)}
    end
  end

  defp release_stream_chunks(acc, []), do: acc

  defp release_stream_chunks(acc, chunks) do
    Enum.reduce(chunks, acc, fn text, acc ->
      acc = ensure_sse_started(acc)

      payload = %{
        "id" => "chatcmpl_stream_#{acc.receipt_id}",
        "object" => "chat.completion.chunk",
        "created" => System.system_time(:second),
        "model" => Map.get(acc.request, "model"),
        "choices" => [%{"index" => 0, "delta" => %{"content" => text}}]
      }

      {:ok, conn} = chunk(acc.conn, "data: #{Jason.encode!(payload)}\n\n")

      %{acc | conn: conn, chunks: [text | acc.chunks]}
    end)
  end

  defp released_content(acc), do: acc.chunks |> Enum.reverse() |> Enum.join()

  defp ensure_sse_started(%{sent?: true} = acc), do: acc

  defp ensure_sse_started(acc) do
    conn =
      acc.conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    %{acc | conn: conn, sent?: true}
  end

  defp maybe_finish_sse(%{sent?: false} = acc), do: acc

  defp maybe_finish_sse(acc) do
    {:ok, conn} = chunk(acc.conn, "data: [DONE]\n\n")
    %{acc | conn: conn}
  end

  defp send_stream_policy_terminal(acc, policy) do
    acc = ensure_sse_started(acc)

    payload = %{
      "wardwright" => %{
        "receipt_id" => acc.receipt_id,
        "event" => policy.status,
        "action" => policy.action,
        "released_to_consumer" => policy.released_to_consumer
      }
    }

    {:ok, conn} = chunk(acc.conn, "data: #{Jason.encode!(payload)}\n\n")
    {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
    %{acc | conn: conn}
  end

  defp stream_attempt(policy, attempt_index, provider) do
    %{
      "attempt_index" => attempt_index,
      "status" => policy.status,
      "action" => policy.action,
      "trigger_count" => policy.trigger_count,
      "released_to_consumer" => policy.released_to_consumer,
      "called_provider" => Map.get(provider, :called_provider, false),
      "mock" => Map.get(provider, :mock, true),
      "selected_model" => Map.get(provider, :selected_model),
      "provider_status" => Map.get(provider, :status),
      "provider_latency_ms" => Map.get(provider, :latency_ms),
      "generated_bytes" => policy.generated_bytes,
      "released_bytes" => policy.released_bytes,
      "held_bytes" => policy.held_bytes,
      "max_held_bytes" => Map.get(policy, :max_held_bytes, 0),
      "max_hold_ms" => Map.get(policy, :max_hold_ms),
      "max_observed_hold_ms" => Map.get(policy, :max_observed_hold_ms, 0),
      "rewritten_bytes" => policy.rewritten_bytes,
      "blocked_bytes" => policy.blocked_bytes
    }
    |> ReceiptBuilder.reject_blank()
  end

  defp stream_retry_budget(%{"action" => action} = trigger_event, _active_retry_budget)
       when action in ["retry", "retry_with_reminder"] do
    trigger_event
    |> Map.get("max_retries", 1)
    |> ReceiptBuilder.integer_value()
    |> max(0)
  end

  defp stream_retry_budget(_trigger_event, active_retry_budget), do: active_retry_budget

  defp stream_retry_request(request, %{"action" => "retry_with_reminder", "reminder" => reminder})
       when is_binary(reminder) do
    reminder = String.trim(reminder)

    if reminder == "" do
      {request, false}
    else
      message = %{
        "role" => "system",
        "name" => "wardwright_stream_policy_reminder",
        "content" => reminder
      }

      request =
        Map.update(request, "messages", [message], fn
          messages when is_list(messages) -> messages ++ [message]
          _other -> [message]
        end)

      {request, true}
    end
  end

  defp stream_retry_request(request, _trigger_event), do: {request, false}

  defp provider_error_stream_policy(provider, retry_count, max_retries, attempts) do
    attempts =
      attempts ++
        [
          %{
            "attempt_index" => length(attempts),
            "status" => "provider_error",
            "called_provider" => Map.get(provider, :called_provider, true),
            "mock" => Map.get(provider, :mock, false),
            "provider_status" => Map.get(provider, :status),
            "provider_latency_ms" => Map.get(provider, :latency_ms),
            "provider_error" => Map.get(provider, :error)
          }
          |> ReceiptBuilder.reject_blank()
        ]

    %{
      status: "provider_error",
      trigger_count: 0,
      action: nil,
      events: [],
      chunks: [],
      released_to_consumer: false,
      retry_count: retry_count,
      max_retries: max_retries,
      attempts: attempts,
      generated_bytes: sum_attempt_bytes(attempts, "generated_bytes"),
      released_bytes: sum_attempt_bytes(attempts, "released_bytes"),
      held_bytes: sum_attempt_bytes(attempts, "held_bytes"),
      rewritten_bytes: sum_attempt_bytes(attempts, "rewritten_bytes"),
      blocked_bytes: sum_attempt_bytes(attempts, "blocked_bytes"),
      called_provider: Map.get(provider, :called_provider, true),
      mock: Map.get(provider, :mock, false),
      provider_latency_ms: stream_latency_ms(attempts),
      provider_error: Map.get(provider, :error)
    }
  end

  defp stream_latency_ms(attempts) do
    Enum.reduce(attempts, 0, fn attempt, total ->
      total + (ReceiptBuilder.integer_value(Map.get(attempt, "provider_latency_ms")) || 0)
    end)
  end

  defp sum_attempt_bytes(attempts, key) do
    Enum.reduce(attempts, 0, fn attempt, total ->
      total + (ReceiptBuilder.integer_value(Map.get(attempt, key)) || 0)
    end)
  end

  defp allow_mock_stream_chunks? do
    Application.get_env(:wardwright, :allow_mock_stream_chunks, false)
  end

  defp record_runtime_event(model, caller, type, fields) do
    version = Wardwright.current_config()["version"]

    case Wardwright.Runtime.record_session_event(
           model,
           version,
           RequestContext.session_id(caller),
           type,
           fields
         ) do
      {:ok, _event} -> :ok
      _ -> :ok
    end
  end

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end
