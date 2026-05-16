defmodule WardwrightWeb.ReceiptBuilder do
  @moduledoc false

  @tool_context_key "tool_context"

  def build(status, model, caller, request, decision, called_provider, policy) do
    receipt_id = "rcpt_" <> random_hex(8)
    created_at = System.system_time(:second)

    %{
      "receipt_schema" => "v1",
      "receipt_id" => receipt_id,
      "created_at" => created_at,
      "run_id" => get_in(caller, ["run_id", "value"]),
      "synthetic_model" => model,
      "synthetic_version" => Wardwright.current_config()["version"],
      "simulation" => status == "simulated",
      "caller" => caller,
      "request" => %{
        "model" => Map.get(request, "model"),
        "normalized_model" => model,
        "estimated_prompt_tokens" => decision.estimated_prompt_tokens,
        "stream" => Map.get(request, "stream", false),
        "message_count" => length(Map.get(request, "messages", [])),
        "prompt_transforms" => Wardwright.current_config()["prompt_transforms"],
        "structured_output" => Wardwright.current_config()["structured_output"],
        @tool_context_key => policy["tool_context"]
      },
      "decision" => %{
        "strategy" => decision.combine_strategy,
        "route_type" => decision.route_type,
        "route_id" => decision.route_id,
        "selected_provider" => decision.selected_provider,
        "selected_model" => decision.selected_model,
        "selected_context_window" => decision.selected_context_window,
        "selected_models" => decision.selected_models,
        "fallback_models" => decision.fallback_models,
        "fallback_used" => decision.fallback_used,
        "route_blocked" => decision.route_blocked,
        "policy_route_constraints" => decision.policy_route_constraints,
        "estimated_prompt_tokens" => decision.estimated_prompt_tokens,
        "skipped" => decision.skipped,
        "reason" => decision.reason,
        "rule" => decision.rule,
        "governance" => Wardwright.current_config()["governance"],
        @tool_context_key => policy["tool_context"] || Wardwright.ToolContext.normalize(request),
        "tool_policy_selectors" => policy["tool_policy_selectors"],
        "policy_actions" => policy["actions"],
        "policy_conflicts" => policy["conflicts"]
      },
      "attempts" => [
        %{
          "provider_id" => decision.selected_model |> String.split("/") |> List.first(),
          "model" => decision.selected_model,
          "status" => status,
          "mock" => true,
          "called_provider" => called_provider
        }
      ],
      "final" => %{
        "status" => status,
        "selected_model" => decision.selected_model,
        "stream_trigger_count" => 0,
        "alert_count" => policy["alert_count"],
        "alert_delivery" => Map.get(policy, "alert_delivery", []),
        "tool_policy" => policy["tool_policy"],
        "events" => policy["events"],
        "receipt_recorded_at" =>
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      },
      "events" => receipt_events(receipt_id, created_at, status, decision, called_provider)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def apply_provider_outcome(receipt, provider) do
    receipt
    |> update_in(["attempts", Access.at(0)], fn attempt ->
      attempt
      |> Map.put("status", provider.status)
      |> Map.put("mock", provider.mock)
      |> Map.put("called_provider", provider.called_provider)
      |> Map.put("latency_ms", provider.latency_ms)
      |> put_if_present("provider_id", provider_id_from_model(Map.get(provider, :selected_model)))
      |> put_if_present("model", Map.get(provider, :selected_model))
      |> put_if_present("provider_metadata", Map.get(provider, :provider_metadata))
      |> put_if_present("provider_error", provider.error)
    end)
    |> update_in(["final"], fn final ->
      final
      |> Map.put("status", provider.status)
      |> put_if_present("selected_model", Map.get(provider, :selected_model))
      |> put_if_present("structured_output", Map.get(provider, :structured_output))
      |> put_if_present("stream_policy", stream_policy_receipt(Map.get(provider, :stream_policy)))
      |> put_stream_policy_summary(Map.get(provider, :stream_policy))
      |> put_if_present("provider_metadata", Map.get(provider, :provider_metadata))
      |> put_if_present("provider_error", provider.error)
    end)
  end

  def chat_response(request, receipt, decision, provider_content) do
    completion_tokens = 18

    content =
      provider_content ||
        "Mock Wardwright response routed to #{decision.selected_model}. Estimated prompt tokens: #{decision.estimated_prompt_tokens}."

    %{
      "id" => "chatcmpl_" <> receipt["receipt_id"],
      "object" => "chat.completion",
      "created" => System.system_time(:second),
      "model" => Map.get(request, "model"),
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => content
          },
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{
        "prompt_tokens" => decision.estimated_prompt_tokens,
        "completion_tokens" => completion_tokens,
        "total_tokens" => decision.estimated_prompt_tokens + completion_tokens
      },
      "wardwright" => %{
        "receipt_id" => receipt["receipt_id"],
        "selected_model" => decision.selected_model,
        "status" => get_in(receipt, ["final", "status"]),
        "provider_error" => get_in(receipt, ["final", "provider_error"]),
        "structured_output" => get_in(receipt, ["final", "structured_output"]),
        "stream_policy" => get_in(receipt, ["final", "stream_policy"]),
        "alert_delivery" => get_in(receipt, ["final", "alert_delivery"])
      }
    }
  end

  def response_status(receipt) do
    case get_in(receipt, ["final", "status"]) do
      status when status in ["completed", "completed_after_guard"] -> 200
      "policy_failed_closed" -> 429
      "provider_error" -> 502
      "exhausted_rule_budget" -> 422
      "exhausted_guard_budget" -> 422
      "stream_policy_blocked" -> 422
      "stream_policy_latency_exceeded" -> 422
      "stream_policy_retry_context_exceeded" -> 422
      "stream_policy_retry_skipped_after_release" -> 409
      "stream_policy_retry_required" -> 409
      _ -> 200
    end
  end

  def reject_blank(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  def integer_value(value) when is_integer(value), do: value

  def integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  def integer_value(_value), do: nil

  def put_if_present(map, _key, nil), do: map
  def put_if_present(map, key, value), do: Map.put(map, key, value)

  defp provider_id_from_model(model) when is_binary(model) do
    model |> String.split("/", parts: 2) |> List.first()
  end

  defp provider_id_from_model(_model), do: nil

  defp put_stream_policy_summary(final, nil), do: final

  defp put_stream_policy_summary(final, stream_policy) do
    final
    |> Map.put("stream_trigger_count", stream_policy.trigger_count)
    |> put_if_present("stream_policy_action", stream_policy.action)
    |> put_stream_route_transitions(stream_policy)
  end

  defp put_stream_route_transitions(final, stream_policy) do
    transitions =
      stream_policy
      |> Map.get(:events, [])
      |> Enum.filter(&(Map.get(&1, "type") == "attempt.retry_rerouted"))
      |> Enum.map(fn event ->
        %{
          "phase" => "stream_retry",
          "reason" => Map.get(event, "reason"),
          "from_model" => Map.get(event, "from_selected_model"),
          "to_model" => Map.get(event, "selected_model"),
          "from_context_window" => Map.get(event, "from_context_window"),
          "to_context_window" => Map.get(event, "context_window"),
          "estimated_prompt_tokens" => Map.get(event, "estimated_prompt_tokens"),
          "route_type" => Map.get(event, "route_type"),
          "fallback_used" => Map.get(event, "fallback_used")
        }
        |> reject_blank()
      end)

    case transitions do
      [] -> final
      _ -> Map.put(final, "route_transitions", transitions)
    end
  end

  defp stream_policy_receipt(nil), do: nil

  defp stream_policy_receipt(stream_policy) do
    %{
      "status" => stream_policy.status,
      "trigger_count" => stream_policy.trigger_count,
      "action" => stream_policy.action,
      "events" => stream_policy.events,
      "released_to_consumer" => stream_policy.released_to_consumer,
      "retry_count" => Map.get(stream_policy, :retry_count, 0),
      "max_retries" => Map.get(stream_policy, :max_retries, 0),
      "attempts" => Map.get(stream_policy, :attempts, []),
      "generated_bytes" => Map.get(stream_policy, :generated_bytes, 0),
      "released_bytes" => Map.get(stream_policy, :released_bytes, 0),
      "held_bytes" => Map.get(stream_policy, :held_bytes, 0),
      "max_held_bytes" => Map.get(stream_policy, :max_held_bytes, 0),
      "max_hold_ms" => Map.get(stream_policy, :max_hold_ms),
      "max_observed_hold_ms" => Map.get(stream_policy, :max_observed_hold_ms, 0),
      "rewritten_bytes" => Map.get(stream_policy, :rewritten_bytes, 0),
      "blocked_bytes" => Map.get(stream_policy, :blocked_bytes, 0)
    }
  end

  defp receipt_events(receipt_id, created_at, status, decision, called_provider) do
    [
      %{
        "event_id" => receipt_id <> ":1",
        "receipt_id" => receipt_id,
        "sequence" => 1,
        "type" => "route.selected",
        "created_at" => created_at,
        "selected_provider" => decision.selected_provider,
        "selected_model" => decision.selected_model
      },
      %{
        "event_id" => receipt_id <> ":2",
        "receipt_id" => receipt_id,
        "sequence" => 2,
        "type" => "provider.attempted",
        "created_at" => created_at,
        "called_provider" => called_provider
      },
      %{
        "event_id" => receipt_id <> ":3",
        "receipt_id" => receipt_id,
        "sequence" => 3,
        "type" => "receipt.finalized",
        "created_at" => created_at,
        "status" => status
      }
    ]
  end

  defp random_hex(bytes) do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
