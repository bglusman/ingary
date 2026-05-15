defmodule Wardwright.PolicyProjection do
  @moduledoc false

  @patterns [
    %{
      "id" => "tts-retry",
      "title" => "Time-travel stream retry",
      "category" => "response.streaming",
      "promise" =>
        "Hold a bounded stream horizon, catch prohibited output before release, then retry once with a precise reminder."
    },
    %{
      "id" => "ambiguous-success",
      "title" => "Ambiguous success alert",
      "category" => "output.finalizing",
      "promise" =>
        "Detect final answers that claim completion while required artifacts or fields are missing."
    },
    %{
      "id" => "route-privacy",
      "title" => "Private context route gate",
      "category" => "route.selecting",
      "promise" =>
        "Keep private-risk requests on approved local routes unless cloud escalation is explicitly allowed."
    }
  ]

  def patterns, do: @patterns

  def pattern(pattern_id) do
    Enum.find(@patterns, &(&1["id"] == pattern_id)) || hd(@patterns)
  end

  def projection(pattern_id, config \\ Wardwright.current_config()) do
    pattern = pattern(pattern_id)

    %{
      "projection_schema" => "wardwright.policy_projection.v1",
      "artifact" => artifact(pattern, config),
      "engine" => engine(pattern["id"]),
      "phases" => phases(pattern["id"], config),
      "effects" => effects(pattern["id"]),
      "conflicts" => conflicts(pattern["id"]),
      "opaque_regions" => opaque_regions(pattern["id"]),
      "warnings" => warnings(pattern["id"])
    }
  end

  def simulations(pattern_id, config \\ Wardwright.current_config()) do
    artifact_hash = artifact(pattern(pattern_id), config)["artifact_hash"]

    pattern_id
    |> simulation_cases()
    |> Enum.map(&Map.put(&1, "artifact_hash", artifact_hash))
  end

  defp artifact(pattern, config) do
    normalized = %{
      "pattern_id" => pattern["id"],
      "config_version" => Map.get(config, "version"),
      "governance" => Map.get(config, "governance", []),
      "stream_rules" => Map.get(config, "stream_rules", []),
      "structured_output" => Map.get(config, "structured_output")
    }

    hash =
      :sha256
      |> :crypto.hash(Jason.encode!(normalized))
      |> Base.encode16(case: :lower)

    %{
      "artifact_id" => "#{pattern["id"]}-#{Map.get(config, "synthetic_model", "policy")}",
      "artifact_hash" => "sha256:#{hash}",
      "policy_version" => "draft.#{pattern["id"]}.001",
      "normalized_format" => "yaml"
    }
  end

  defp engine("route-privacy") do
    %{
      "engine_id" => "starlark-route-gate",
      "display_name" => "Starlark route gate",
      "language" => "starlark",
      "version" => "0.1",
      "capabilities" => %{
        "phases" => ["route.selecting", "receipt.finalized"],
        "can_static_analyze" => true,
        "can_generate_scenarios" => true,
        "can_explain_trace" => true,
        "can_emit_source_spans" => true
      }
    }
  end

  defp engine("ambiguous-success") do
    %{
      "engine_id" => "hybrid-output-review",
      "display_name" => "Hybrid output review",
      "language" => "hybrid",
      "version" => "0.1",
      "capabilities" => %{
        "phases" => ["output.finalizing", "receipt.finalized"],
        "can_static_analyze" => true,
        "can_generate_scenarios" => true,
        "can_explain_trace" => true,
        "can_emit_source_spans" => true
      }
    }
  end

  defp engine(_pattern_id) do
    %{
      "engine_id" => "structured-stream-primitives",
      "display_name" => "Structured stream primitives",
      "language" => "structured",
      "version" => "0.1",
      "capabilities" => %{
        "phases" => ["response.streaming", "receipt.finalized"],
        "can_static_analyze" => true,
        "can_generate_scenarios" => true,
        "can_explain_trace" => true,
        "can_emit_source_spans" => false
      }
    }
  end

  defp phases("ambiguous-success", _config) do
    [
      %{
        "id" => "output.finalizing",
        "title" => "Final Output",
        "description" => "Compare final text claims against expected artifact facts.",
        "nodes" => [
          node(
            "success.claim-detector",
            "completion claim",
            "primitive",
            "output.finalizing",
            "Detects final text that claims the work is done.",
            "exact",
            ["final.text"],
            ["policy.match"],
            ["classify_claim"]
          ),
          node(
            "success.artifact-check",
            "artifact check",
            "rule",
            "output.finalizing",
            "Checks whether required artifact metadata is present.",
            "declared",
            ["expected_artifacts", "receipt.metadata"],
            ["policy.action"],
            ["alert_operator", "annotate_receipt"]
          )
        ]
      }
    ]
  end

  defp phases("route-privacy", _config) do
    [
      %{
        "id" => "route.selecting",
        "title" => "Route",
        "description" => "Constrain route candidates before provider selection.",
        "nodes" => [
          node(
            "privacy.private-risk-branch",
            "private risk branch",
            "function",
            "route.selecting",
            "Starlark branch checks private-data-risk and cloud escalation approval.",
            "inferred",
            ["request.annotations", "caller.approvals", "route.candidates"],
            ["route.allowed_targets"],
            ["restrict_routes"],
            %{"file" => "policy.star", "start_line" => 4, "end_line" => 11}
          ),
          node(
            "privacy.opaque-helper",
            "risk helper",
            "opaque_region",
            "route.selecting",
            "Helper logic is declared pure but cannot be fully classified by the projection adapter.",
            "opaque",
            ["request.annotations"],
            [],
            ["classify_risk"],
            %{"file" => "policy.star", "start_line" => 13, "end_line" => 19}
          )
        ]
      }
    ]
  end

  defp phases(_pattern_id, config) do
    stream_rules = Map.get(config, "stream_rules", [])

    [
      %{
        "id" => "response.streaming",
        "title" => "Stream",
        "description" => "Evaluate bounded stream windows before bytes are released.",
        "nodes" => [
          node(
            "tts.no-old-client",
            "no-old-client",
            "primitive",
            "response.streaming",
            stream_summary(stream_rules),
            "exact",
            ["stream.window"],
            ["attempt.abort_reason"],
            ["match_regex", "abort_attempt"]
          ),
          node(
            "tts.retry-arbiter",
            "retry arbiter",
            "arbiter",
            "response.streaming",
            "Retry once with a reminder, then block final output on repeat violation.",
            "exact",
            ["attempt.retry_count", "policy.match"],
            ["request.system_reminder", "final.status"],
            ["retry_with_reminder", "block_final"]
          )
        ]
      },
      %{
        "id" => "receipt.finalized",
        "title" => "Receipt",
        "description" => "Persist policy events for audit and future regression fixtures.",
        "nodes" => [
          node(
            "tts.receipt-events",
            "receipt events",
            "rule",
            "receipt.finalized",
            "Record stream hold, match, abort, retry, and final status events.",
            "exact",
            ["policy.events", "attempt.status"],
            ["receipt.events"],
            ["annotate_receipt"]
          )
        ]
      }
    ]
  end

  defp node(
         id,
         label,
         kind,
         phase,
         summary,
         confidence,
         reads,
         writes,
         actions,
         source_span \\ nil
       ) do
    %{
      "id" => id,
      "label" => label,
      "kind" => kind,
      "phase" => phase,
      "summary" => summary,
      "confidence" => confidence,
      "reads" => reads,
      "writes" => writes,
      "actions" => actions,
      "source_span" => source_span
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp stream_summary([]), do: "Match prohibited output inside the unreleased stream horizon."

  defp stream_summary(rules) do
    ids =
      rules
      |> Enum.map(&Map.get(&1, "id", "stream-rule"))
      |> Enum.join(", ")

    "Project configured stream rules into a holdback detector: #{ids}."
  end

  defp effects("ambiguous-success") do
    [
      effect(
        "effect.alert",
        "success.artifact-check",
        "output.finalizing",
        "alert_operator",
        "operator",
        "declared"
      ),
      effect(
        "effect.annotate",
        "success.artifact-check",
        "receipt.finalized",
        "annotate",
        "receipt",
        "declared"
      )
    ]
  end

  defp effects("route-privacy") do
    [
      effect(
        "effect.restrict",
        "privacy.private-risk-branch",
        "route.selecting",
        "restrict_routes",
        "route",
        "inferred"
      )
    ]
  end

  defp effects(_pattern_id) do
    [
      effect(
        "effect.abort",
        "tts.no-old-client",
        "response.streaming",
        "abort_attempt",
        "attempt",
        "exact"
      ),
      effect(
        "effect.retry",
        "tts.retry-arbiter",
        "response.streaming",
        "retry_with_reminder",
        "request",
        "exact"
      ),
      effect(
        "effect.block",
        "tts.retry-arbiter",
        "response.streaming",
        "block_final",
        "final",
        "exact"
      ),
      effect(
        "effect.receipt",
        "tts.receipt-events",
        "receipt.finalized",
        "annotate",
        "receipt",
        "exact"
      )
    ]
  end

  defp effect(id, node_id, phase, effect, target, confidence) do
    %{
      "id" => id,
      "node_id" => node_id,
      "phase" => phase,
      "effect" => effect,
      "target" => target,
      "confidence" => confidence
    }
  end

  defp conflicts("ambiguous-success") do
    [
      %{
        "id" => "conflict.block-alert-choice",
        "class" => "ambiguous",
        "node_ids" => ["success.artifact-check"],
        "summary" =>
          "The artifact can alert or block; activation needs the operator to choose the promise.",
        "required_resolution" => "select alert-only or block-final before activation"
      }
    ]
  end

  defp conflicts("route-privacy") do
    [
      %{
        "id" => "conflict.route-starvation",
        "class" => "ordered",
        "node_ids" => ["privacy.private-risk-branch"],
        "summary" =>
          "Local-only restriction must run before fallback selection or cloud fallback could win.",
        "required_resolution" => "route gate priority precedes provider fallback"
      }
    ]
  end

  defp conflicts(_pattern_id) do
    [
      %{
        "id" => "conflict.retry-block-order",
        "class" => "ordered",
        "node_ids" => ["tts.no-old-client", "tts.retry-arbiter"],
        "summary" =>
          "Abort happens before retry arbitration; repeated violation resolves to block_final.",
        "required_resolution" => "priority order is encoded by the compiled stream plan"
      }
    ]
  end

  defp opaque_regions("route-privacy") do
    [
      %{
        "id" => "opaque.risk-helper",
        "node_id" => "privacy.opaque-helper",
        "reason" =>
          "Static adapter cannot prove all helper branches return only deterministic booleans.",
        "review_requirement" =>
          "Require scenario coverage for approved cloud override and private-risk denial."
      }
    ]
  end

  defp opaque_regions(_pattern_id), do: []

  defp warnings("route-privacy") do
    [
      "Projection is partly inferred from Starlark host API calls; source span review remains required."
    ]
  end

  defp warnings("ambiguous-success") do
    [
      "Classifier wording can drift; pin generated false-positive examples as regression fixtures."
    ]
  end

  defp warnings(_pattern_id), do: ["Adds stream latency up to the configured holdback horizon."]

  defp simulation_cases("ambiguous-success") do
    [
      %{
        "simulation_schema" => "wardwright.policy_simulation.v1",
        "scenario_id" => "missing-artifact",
        "title" => "Completion claim missing artifact",
        "engine_id" => "hybrid-output-review",
        "input_summary" => "Final answer says export is ready, but artifact metadata is empty.",
        "expected_behavior" => "Receipt is annotated and operator alert is emitted.",
        "verdict" => "passed",
        "trace" => [
          trace(
            "a1",
            "output.finalizing",
            "success.claim-detector",
            "match",
            "claim detected",
            "final text contains completed/ready language",
            "warn"
          ),
          trace(
            "a2",
            "output.finalizing",
            "success.artifact-check",
            "state_read",
            "metadata missing",
            "expected artifact slot has no attached export",
            "warn"
          ),
          trace(
            "a3",
            "receipt.finalized",
            "success.artifact-check",
            "action",
            "alert emitted",
            "operator alert and receipt annotation would be recorded",
            "pass"
          )
        ],
        "receipt_preview" => %{
          "events" => [%{"type" => "policy.alert", "rule_id" => "missing-artifact-after-success"}],
          "final_status" => "completed_with_alert"
        }
      }
    ]
  end

  defp simulation_cases("route-privacy") do
    [
      %{
        "simulation_schema" => "wardwright.policy_simulation.v1",
        "scenario_id" => "cloud-denied",
        "title" => "Private context blocks cloud fallback",
        "engine_id" => "starlark-route-gate",
        "input_summary" =>
          "Request has private-data-risk annotation and no cloud escalation approval.",
        "expected_behavior" => "Managed cloud route is removed before fallback selection.",
        "verdict" => "inconclusive",
        "trace" => [
          trace(
            "p1",
            "route.selecting",
            "privacy.opaque-helper",
            "warning",
            "opaque helper",
            "risk helper result is accepted from declared host API behavior",
            "warn",
            %{"file" => "policy.star", "start_line" => 13, "end_line" => 19}
          ),
          trace(
            "p2",
            "route.selecting",
            "privacy.private-risk-branch",
            "action",
            "route restricted",
            "allowed targets reduced to local providers",
            "pass",
            %{"file" => "policy.star", "start_line" => 4, "end_line" => 11}
          )
        ],
        "receipt_preview" => %{
          "decision" => %{
            "skipped" => [%{"node" => "managed-safe", "reason" => "policy_route_gate"}]
          },
          "final_status" => "simulated"
        }
      }
    ]
  end

  defp simulation_cases(_pattern_id) do
    [
      %{
        "simulation_schema" => "wardwright.policy_simulation.v1",
        "scenario_id" => "split-trigger",
        "title" => "Split trigger before release",
        "engine_id" => "structured-stream-primitives",
        "input_summary" => "Provider emits OldClient( split across held chunks.",
        "expected_behavior" =>
          "No violating bytes are released; attempt aborts and retries once.",
        "verdict" => "passed",
        "trace" => [
          trace(
            "t1",
            "response.streaming",
            "tts.no-old-client",
            "input",
            "chunk held",
            "avoid introducing Old",
            "info"
          ),
          trace(
            "t2",
            "response.streaming",
            "tts.no-old-client",
            "match",
            "regex matched",
            "Client( completes the prohibited span inside the holdback window",
            "block"
          ),
          trace(
            "t3",
            "response.streaming",
            "tts.retry-arbiter",
            "action",
            "retry selected",
            "attempt aborted before release and retry reminder injected",
            "pass"
          ),
          trace(
            "t4",
            "receipt.finalized",
            "tts.receipt-events",
            "receipt_event",
            "receipt preview",
            "stream.rule_matched and attempt.retry_requested events recorded",
            "info"
          )
        ],
        "receipt_preview" => %{
          "receipt_id" => "simulated-policy-receipt",
          "synthetic_model" => Wardwright.synthetic_model(),
          "policy_version" => "draft.ttsr.001",
          "stream" => %{
            "rule_matched" => "no-old-client",
            "released_to_consumer" => false,
            "abort_offset" => 42,
            "retry_attempted" => true
          },
          "events" => [
            %{
              "type" => "stream.window_held",
              "rule_id" => "no-old-client",
              "horizon_bytes" => 4096
            },
            %{
              "type" => "stream.rule_matched",
              "rule_id" => "no-old-client",
              "match_kind" => "regex"
            },
            %{"type" => "attempt.aborted", "reason" => "tts_rule_matched"},
            %{"type" => "attempt.retry_requested", "reminder_id" => "no-old-client.reminder"}
          ]
        }
      }
    ]
  end

  defp trace(id, phase, node_id, kind, label, detail, severity, source_span \\ nil) do
    %{
      "id" => id,
      "phase" => phase,
      "node_id" => node_id,
      "kind" => kind,
      "label" => label,
      "detail" => detail,
      "severity" => severity,
      "source_span" => source_span
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
