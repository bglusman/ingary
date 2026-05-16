defmodule Wardwright.ProviderCapabilities do
  @moduledoc """
  Versioned provider capability records exposed at the provider API boundary.

  These records are descriptive for now. Runtime enforcement should eventually
  reject policy-relevant options that a selected adapter cannot honor.
  """

  defstruct [
    :endpoint_shape,
    :stream_format,
    :auth_scheme,
    :cancellation_mechanism,
    :cancellation_confidence,
    terminal_metadata: [],
    unsupported_stream_delta_fields: [],
    unsupported_options_policy: "not_applicable"
  ]

  @schema "wardwright.provider_capabilities.v1"
  @schema_key "schema"
  @endpoint_shape_key "endpoint_shape"
  @stream_format_key "stream_format"
  @auth_scheme_key "auth_scheme"
  @terminal_metadata_key "terminal_metadata"
  @cancellation_key "cancellation"
  @mechanism_key "mechanism"
  @confidence_key "confidence"
  @unsupported_stream_delta_fields_key "unsupported_stream_delta_fields"
  @unsupported_options_policy_key "unsupported_options_policy"

  def for_provider("ollama", _credential_source) do
    %__MODULE__{
      endpoint_shape: "ollama_chat_api",
      stream_format: "ollama_ndjson",
      auth_scheme: "none",
      terminal_metadata: [
        "done",
        "done_reason",
        "total_duration",
        "load_duration",
        "prompt_eval_count",
        "eval_count"
      ],
      cancellation_mechanism: "task_cancel_httpc_request",
      cancellation_confidence: "needs_live_provider_smoke",
      unsupported_options_policy: "ignore_safe_options_fail_later_for_policy_relevant_options"
    }
    |> to_map()
  end

  def for_provider("openai-compatible", credential_source) do
    %__MODULE__{
      endpoint_shape: "openai_chat_completions",
      stream_format: "openai_sse",
      auth_scheme: bearer_auth_scheme(credential_source),
      terminal_metadata: [
        "finish_reason",
        "choice_index",
        "usage",
        "system_fingerprint",
        "refusal",
        "done"
      ],
      cancellation_mechanism: "task_cancel_httpc_request",
      cancellation_confidence: "needs_live_provider_smoke",
      unsupported_stream_delta_fields: ["role", "tool_calls", "logprobs"],
      unsupported_options_policy: "ignore_safe_options_fail_later_for_policy_relevant_options"
    }
    |> to_map()
  end

  def for_provider(_kind, _credential_source) do
    %__MODULE__{
      endpoint_shape: "wardwright_mock",
      stream_format: "synthetic_chunks",
      auth_scheme: "none",
      cancellation_mechanism: "local_task",
      cancellation_confidence: "deterministic_local"
    }
    |> to_map()
  end

  def to_map(%__MODULE__{} = capabilities) do
    %{
      @schema_key => @schema,
      @endpoint_shape_key => capabilities.endpoint_shape,
      @stream_format_key => capabilities.stream_format,
      @auth_scheme_key => capabilities.auth_scheme,
      @terminal_metadata_key => capabilities.terminal_metadata,
      @cancellation_key => %{
        @mechanism_key => capabilities.cancellation_mechanism,
        @confidence_key => capabilities.cancellation_confidence
      },
      @unsupported_stream_delta_fields_key => capabilities.unsupported_stream_delta_fields,
      @unsupported_options_policy_key => capabilities.unsupported_options_policy
    }
  end

  defp bearer_auth_scheme("none"), do: "none"
  defp bearer_auth_scheme(_credential_source), do: "bearer"
end
