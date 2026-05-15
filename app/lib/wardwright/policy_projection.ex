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
      "route_workbench" => route_workbench(pattern["id"], config),
      "assistant_contract" => assistant_contract(pattern["id"]),
      "governance_escalation" => governance_escalation(pattern["id"]),
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

  defp route_workbench("route-privacy", config) do
    route_graph = route_graph(config)
    local_model = primary_model(config)
    managed_model = secondary_model(config)
    local_provider = provider_prefix(local_model)
    baseline_short = Wardwright.RoutePlanner.select(config, 8_000)
    baseline_large = Wardwright.RoutePlanner.select(config, 96_000)

    restricted =
      Wardwright.RoutePlanner.select(config, 96_000, %{"allowed_targets" => [local_provider]})

    forced =
      Wardwright.RoutePlanner.select(config, 8_000, %{
        "forced_model" => managed_model
      })

    blocked = Wardwright.RoutePlanner.select(config, 96_000, %{"allowed_targets" => ["sandbox"]})

    %{
      "summary" =>
        "Baseline route candidates come from the synthetic model route graph. Policy overlays run before provider selection and explain how the artifact narrowed, forced, rerouted, or blocked that baseline.",
      "route_root" => route_graph["root"],
      "nodes" => route_graph["nodes"],
      "baseline_candidates" => [
        route_candidate("short local fit", baseline_short),
        route_candidate("large managed fit", baseline_large)
      ],
      "policy_constraints" => [
        %{
          "action" => "restrict_routes",
          "constraint" => "allowed_targets = [\"#{local_provider}\"]",
          "source_node_id" => "privacy.private-risk-branch",
          "receipt_field" => "policy_route_constraints.allowed_targets",
          "outcome" => "managed target removed; route fails closed if local cannot fit"
        },
        %{
          "action" => "switch_model",
          "constraint" => "forced_model = \"#{managed_model}\"",
          "source_node_id" => "privacy.private-risk-branch",
          "receipt_field" => "policy_route_constraints.forced_model",
          "outcome" => "baseline selector is bypassed by a policy_override route"
        },
        %{
          "action" => "reroute",
          "constraint" => "forced_model = remediation target after failed attempt",
          "source_node_id" => "privacy.private-risk-branch",
          "receipt_field" => "policy_route_constraints.forced_model",
          "outcome" =>
            "same route override contract as switch_model, triggered after policy evidence"
        },
        %{
          "action" => "block",
          "constraint" => "allowed route set is empty",
          "source_node_id" => "privacy.private-risk-branch",
          "receipt_field" => "route_blocked",
          "outcome" => "planner records route_blocked instead of falling through"
        }
      ],
      "policy_outcomes" => [
        route_outcome("restricted private request", "restrict_routes", restricted),
        route_outcome("forced managed review", "switch_model", forced),
        route_outcome("empty allow-list", "block", blocked)
      ],
      "model_differences" => [
        %{
          "model" => local_model,
          "baseline_role" => "preferred for private short-context work",
          "policy_overlay" => "kept by local-only restriction",
          "risk_note" => "context window can still cause fail-closed route_blocked"
        },
        %{
          "model" => managed_model,
          "baseline_role" => "selected for larger prompts and available as fallback",
          "policy_overlay" => "removed unless explicit cloud escalation exists",
          "risk_note" => "can be forced by switch_model/reroute when the artifact authorizes it"
        }
      ]
    }
  end

  defp route_workbench(_pattern_id, config) do
    route_graph = route_graph(config)
    baseline = Wardwright.RoutePlanner.select(config, 8_000)

    %{
      "summary" =>
        "Route graph context is shown for orientation; this policy pattern does not currently emit route constraints.",
      "route_root" => route_graph["root"],
      "nodes" => route_graph["nodes"],
      "baseline_candidates" => [route_candidate("baseline fit", baseline)],
      "policy_constraints" => [],
      "policy_outcomes" => [],
      "model_differences" => []
    }
  end

  defp route_graph(config) do
    targets = Map.get(config, "targets", [])
    target_ids = Enum.map(targets, &node_id(&1["model"]))

    %{
      "root" => Map.get(config, "route_root", "dispatcher.prompt_length"),
      "nodes" => selector_nodes(config, target_ids) ++ Enum.map(targets, &target_node/1)
    }
  end

  defp selector_nodes(config, default_target_ids) do
    dispatchers =
      config
      |> Map.get("dispatchers", [])
      |> case do
        [] -> [%{"id" => "dispatcher.prompt_length", "models" => default_target_ids}]
        configured -> configured
      end
      |> Enum.map(fn dispatcher ->
        %{
          "id" => dispatcher["id"],
          "type" => "dispatcher",
          "targets" => selector_target_ids(dispatcher, "models"),
          "strategy" => "smallest_context_window"
        }
      end)

    cascades =
      config
      |> Map.get("cascades", [])
      |> Enum.map(fn cascade ->
        %{
          "id" => cascade["id"],
          "type" => "cascade",
          "targets" => selector_target_ids(cascade, "models"),
          "strategy" => "ordered_fallback"
        }
      end)

    alloys =
      config
      |> Map.get("alloys", [])
      |> Enum.map(fn alloy ->
        %{
          "id" => alloy["id"],
          "type" => "alloy",
          "targets" => selector_target_ids(alloy, "constituents"),
          "strategy" => Map.get(alloy, "strategy", "weighted"),
          "partial_context" => Map.get(alloy, "partial_context", false)
        }
      end)

    dispatchers ++ cascades ++ alloys
  end

  defp selector_target_ids(selector, key) do
    selector
    |> Map.get(key, Map.get(selector, "targets", []))
    |> Enum.map(fn
      model when is_binary(model) -> node_id(model)
      %{"model" => model} -> node_id(model)
      other -> node_id(to_string(other))
    end)
  end

  defp target_node(target) do
    %{
      "id" => node_id(target["model"]),
      "type" => "concrete_model",
      "provider_id" => provider_prefix(target["model"]),
      "upstream_model_id" => target["model"],
      "context_window" => target["context_window"]
    }
  end

  defp node_id(model) when is_binary(model), do: String.replace(model, "/", ".")
  defp node_id(model), do: model |> to_string() |> String.replace("/", ".")

  defp primary_model(config) do
    config
    |> Map.get("targets", [])
    |> List.first(%{})
    |> Map.get("model", Wardwright.local_model())
  end

  defp secondary_model(config) do
    config
    |> Map.get("targets", [])
    |> Enum.at(1, %{})
    |> Map.get("model", primary_model(config))
  end

  defp provider_prefix(model) when is_binary(model) do
    model |> String.split("/", parts: 2) |> List.first()
  end

  defp provider_prefix(_model), do: "provider"

  defp route_candidate(label, decision) do
    %{
      "label" => label,
      "route_type" => decision.route_type,
      "route_id" => decision.route_id,
      "selected_model" => decision.selected_model,
      "fallback_models" => decision.fallback_models,
      "skipped" => decision.skipped,
      "reason" => decision.reason
    }
  end

  defp route_outcome(label, action, decision) do
    %{
      "label" => label,
      "action" => action,
      "route_type" => decision.route_type,
      "selected_model" => decision.selected_model || "none",
      "route_blocked" => decision.route_blocked,
      "policy_route_constraints" => decision.policy_route_constraints,
      "skipped" => decision.skipped,
      "reason" => decision.reason
    }
  end

  defp assistant_contract(pattern_id) do
    %{
      "status" => "mocked_static_panel",
      "source_of_truth" =>
        "The assistant may explain and propose, but only the deterministic policy artifact can change enforcement.",
      "system_prompt" =>
        "You are Wardwright's policy assistant. Ground every answer in the active projection, route plan, simulation trace, receipt, and policy artifact hash. Never imply a simulated or proposed rule is active until validate_policy_artifact passes and the operator activates the artifact.",
      "tool_calls" => [
        tool_call("explain_projection", ["artifact_hash", "projection_node_id"]),
        tool_call("simulate_policy", ["artifact_hash", "scenario_id", "input_facts"]),
        tool_call("propose_rule_change", ["artifact_hash", "operator_intent", "affected_phase"]),
        tool_call("inspect_receipt", ["receipt_id", "fields"]),
        tool_call("inspect_route_plan", ["synthetic_model", "route_root", "request_facts"]),
        tool_call("validate_policy_artifact", ["artifact_hash", "candidate_patch"])
      ],
      "mock_messages" => assistant_messages(pattern_id)
    }
  end

  defp tool_call(name, required_args) do
    %{
      "name" => name,
      "required_args" => required_args,
      "mode" => "read_only_or_candidate_patch"
    }
  end

  defp assistant_messages("route-privacy") do
    [
      %{
        "role" => "operator",
        "text" => "Why did the managed model disappear for this private request?"
      },
      %{
        "role" => "assistant",
        "text" =>
          "The active projection shows privacy.private-risk-branch emitted restrict_routes with allowed_targets [local]. I would inspect_route_plan, then inspect_receipt for policy_route_constraints before proposing any artifact change."
      },
      %{
        "role" => "assistant",
        "text" =>
          "If the business intent is cloud review after approval, I can propose_rule_change, but activation still depends on validate_policy_artifact and an operator publishing the deterministic artifact."
      }
    ]
  end

  defp assistant_messages(_pattern_id) do
    [
      %{"role" => "operator", "text" => "Can this policy be made less noisy?"},
      %{
        "role" => "assistant",
        "text" =>
          "I can explain_projection and simulate_policy against fixture cases, then propose a candidate rule patch. The compiled artifact remains the authority."
      }
    ]
  end

  defp governance_escalation("route-privacy") do
    %{
      "status" => "roadmap_mock",
      "mockability" =>
        "Simulation currently records invocation intent only; no external agent is invoked by this LiveView spike.",
      "steps" => [
        escalation_step(
          "1",
          "deterministic",
          "route.selecting",
          "Artifact evaluates private-data-risk"
        ),
        escalation_step(
          "2",
          "deterministic",
          "restrict_routes",
          "Allowed targets narrow to local providers"
        ),
        escalation_step(
          "3",
          "agent_invocation_mock",
          "agent.review_policy_exception",
          "Future policy may ask an agent to gather approval context"
        ),
        escalation_step(
          "4",
          "deterministic",
          "validate_policy_artifact",
          "Only a validated artifact can alter enforcement"
        )
      ]
    }
  end

  defp governance_escalation(_pattern_id) do
    %{
      "status" => "roadmap_mock",
      "mockability" =>
        "Agent escalation is shown as an invocation-only path and is not part of this deterministic policy.",
      "steps" => [
        escalation_step(
          "1",
          "deterministic",
          "policy.match",
          "Compiled artifact evaluates the request"
        ),
        escalation_step(
          "2",
          "agent_invocation_mock",
          "agent.suggest_refinement",
          "Assistant can propose a candidate patch"
        ),
        escalation_step(
          "3",
          "deterministic",
          "validate_policy_artifact",
          "Validation gates activation"
        )
      ]
    }
  end

  defp escalation_step(id, kind, label, detail) do
    %{"id" => id, "kind" => kind, "label" => label, "detail" => detail}
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
