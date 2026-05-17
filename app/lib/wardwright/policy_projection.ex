defmodule Wardwright.PolicyProjection do
  @moduledoc false

  alias Wardwright.PolicyProjection.Contract

  @kind_key "kind"
  @transition_to_key "transition_to"
  @then_key "then"
  @action_key "action"
  @tool_sequence_kind "tool_sequence"
  @tool_loop_threshold_kind "tool_loop_threshold"
  @state_transition_action "state_transition"
  @decision_tool_context_read "decision.tool_context"
  @policy_cache_tool_call_read "policy_cache.session.tool_call"
  @policy_cache_state_read "policy_cache.session.policy_state"
  @policy_actions_write "policy.actions"

  @patterns [
    %{
      "id" => "tts-retry",
      "title" => "Time-travel stream retry",
      "category" => "response.streaming",
      "promise" =>
        "Hold a bounded stream horizon, catch prohibited output before release, then retry once with a precise reminder."
    },
    %{
      "id" => "stream-rewrite-state",
      "title" => "Regex rewrite and state transition",
      "category" => "response.streaming",
      "promise" =>
        "Show related stream regex matches where one rewrites held output and a later match transitions the session into review."
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
    },
    %{
      "id" => "tool-governance",
      "title" => "Tool call governance",
      "category" => "tool.using",
      "promise" =>
        "Normalize tool context, expose tool-sensitive policy review points, and make tool selector/loop rules visible before enforcement."
    }
  ]

  def patterns, do: @patterns

  def pattern_ids, do: Enum.map(@patterns, &Map.fetch!(&1, "id"))

  def state_ids("tts-retry"), do: ["observing", "guarding", "retrying", "recording"]

  def state_ids("stream-rewrite-state"),
    do: ["observing", "rewriting", "review_required", "recording"]

  def state_ids(pattern_id) when is_binary(pattern_id) do
    if pattern_id in pattern_ids() do
      ["active"]
    else
      []
    end
  end

  def pattern(pattern_id) do
    Enum.find(@patterns, &(&1["id"] == pattern_id)) || hd(@patterns)
  end

  def projection(pattern_id, config \\ Wardwright.current_config()) do
    pattern = pattern(pattern_id)
    phases = phases(pattern["id"], config)

    %{
      "projection_schema" => "wardwright.policy_projection.v1",
      "artifact" => artifact(pattern, config),
      "engine" => engine(pattern["id"], config),
      "compiled_plan" => compiled_plan(pattern["id"], config, phases),
      "phases" => phases,
      "state_machine" => state_machine(pattern["id"], phases, config),
      "effects" => effects(pattern["id"], config),
      "conflicts" => conflicts(pattern["id"], config),
      "opaque_regions" => opaque_regions(pattern["id"], config),
      "warnings" => warnings(pattern["id"], config)
    }
  end

  def simulations(pattern_id, config \\ Wardwright.current_config()) do
    artifact_hash = artifact(pattern(pattern_id), config)["artifact_hash"]

    pattern_id
    |> simulation_records(config)
    |> Enum.map(&Map.put(&1, "artifact_hash", artifact_hash))
  end

  def simulation_inputs(pattern_id) do
    Enum.map(simulation_inputs(), fn input ->
      Map.put(input, "relationship", simulation_input_relationship(pattern_id, input["id"]))
    end)
  end

  def simulation_inputs do
    tts_simulation_inputs() ++
      stream_rewrite_simulation_inputs() ++
      ambiguous_success_simulation_inputs()
  end

  defp tts_simulation_inputs do
    [
      %{
        "id" => "split-old-client",
        "title" => "TTSR: split prohibited span",
        "description" => "OldClient( appears across held stream chunks and should trigger retry.",
        "user_input" => "Show me the legacy adapter name in a migration note.",
        "model_response" => "avoid introducing Old\nClient( into the final answer"
      },
      %{
        "id" => "safe-stream",
        "title" => "TTSR: safe stream",
        "description" => "No prohibited span appears, so the stream can release normally.",
        "user_input" => "Write a migration note that avoids deprecated constructors.",
        "model_response" => "Use the current client adapter.\nAvoid legacy constructor names."
      }
    ]
  end

  defp stream_rewrite_simulation_inputs do
    [
      %{
        "id" => "rewrite-then-secret",
        "title" => "Stream: rewrite then transition",
        "description" =>
          "An account identifier is rewritten, then a related token forces review.",
        "user_input" => "Summarize the billing incident without exposing credentials.",
        "model_response" =>
          "account acct_4938 appears in the answer\ntoken_live_4938 follows in the held horizon",
        "history_context" => %{
          "recent_related_secret_matches" => "0",
          "policy_state" => "observing"
        }
      },
      %{
        "id" => "input-and-output-rewrite",
        "title" => "Stream: input and output rewrite",
        "description" =>
          "Private request context is withheld from the provider, then an account identifier is redacted before release.",
        "user_input" =>
          "Summarize the incident. private_context{customer email is alex@example.test}",
        "model_response" =>
          "The billing incident for account acct_4938 can be summarized without the private email.",
        "history_context" => %{
          "recent_related_secret_matches" => "0",
          "policy_state" => "observing"
        }
      },
      %{
        "id" => "rewrite-only",
        "title" => "Stream: rewrite only",
        "description" =>
          "The account identifier is redacted and the rewritten stream is released.",
        "user_input" => "Summarize the billing incident without exposing credentials.",
        "model_response" => "account acct_4938 appears in the answer\nno related secret follows",
        "history_context" => %{
          "recent_related_secret_matches" => "0",
          "policy_state" => "observing"
        }
      },
      %{
        "id" => "no-match",
        "title" => "Stream: no regex match",
        "description" => "No configured regex matches the held chunks.",
        "user_input" => "Write a neutral status update.",
        "model_response" => "ordinary response text\nwith no account ids or secret tokens",
        "history_context" => %{
          "recent_related_secret_matches" => "0",
          "policy_state" => "observing"
        }
      }
    ]
  end

  defp ambiguous_success_simulation_inputs do
    [
      %{
        "id" => "claim-without-artifact",
        "title" => "Artifact: claim without artifact",
        "description" =>
          "The final text claims completion but does not include artifact evidence.",
        "user_input" => "Export the policy audit report as a spreadsheet.",
        "model_response" => "Done, the export is ready for download."
      },
      %{
        "id" => "claim-with-artifact",
        "title" => "Artifact: claim with metadata",
        "description" => "The completion claim is backed by an artifact identifier.",
        "user_input" => "Export the policy audit report as a spreadsheet.",
        "model_response" => "Done, the export is ready. Artifact: report-2026-05-16.xlsx"
      }
    ]
  end

  defp simulation_input_relationship("tts-retry", input_id)
       when input_id in ["split-old-client", "safe-stream"],
       do: "direct"

  defp simulation_input_relationship("stream-rewrite-state", input_id)
       when input_id in [
              "rewrite-then-secret",
              "input-and-output-rewrite",
              "rewrite-only",
              "no-match"
            ],
       do: "direct"

  defp simulation_input_relationship("ambiguous-success", input_id)
       when input_id in ["claim-without-artifact", "claim-with-artifact"],
       do: "direct"

  defp simulation_input_relationship(_pattern_id, _input_id), do: "cross_policy_probe"

  def simulate_input(pattern_id, text, config \\ Wardwright.current_config()) do
    simulate_turn(pattern_id, "", text, config)
  end

  def simulate_turn(pattern_id, user_input, model_response, config \\ Wardwright.current_config()) do
    simulate_turn_with_context(pattern_id, user_input, model_response, %{}, config)
  end

  def simulate_turn_with_context(
        pattern_id,
        user_input,
        model_response,
        history_context,
        config \\ Wardwright.current_config()
      ) do
    artifact_hash = artifact(pattern(pattern_id), config)["artifact_hash"]

    turn = %{
      "user_input" => user_input || "",
      "model_response" => model_response || "",
      "history_context" => normalize_history_context(history_context)
    }

    pattern_id
    |> evaluated_simulation(turn, config)
    |> Map.put("artifact_hash", artifact_hash)
    |> Map.put("scenario_source", "interactive")
    |> Map.put("source", "interactive")
  end

  defp artifact(pattern, config) do
    normalized = %{
      "pattern_id" => pattern["id"],
      "config_version" => Map.get(config, "version"),
      "governance" => Map.get(config, "governance", []),
      "tool_governance" => tool_governance_rules(config),
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

  defp engine("route-privacy", config) do
    route_rules = route_governance_rules(config)
    language = route_engine_language(route_rules)

    %{
      "engine_id" => "request-route-plan",
      "display_name" => "Request route plan",
      "language" => language,
      "version" => "0.1",
      "capabilities" => %{
        "phases" => ["route.selecting", "request.routing", "receipt.finalized"],
        "can_static_analyze" => language != "opaque",
        "can_generate_scenarios" => true,
        "can_explain_trace" => true,
        "can_emit_source_spans" => Enum.any?(route_rules, &is_map(&1["source_span"]))
      }
    }
  end

  defp engine("tool-governance", config) do
    tool_rules = tool_governance_rules(config)
    language = route_engine_language(tool_rules)

    %{
      "engine_id" => "tool-context-plan",
      "display_name" => "Tool context plan",
      "language" => language,
      "version" => "0.1",
      "capabilities" => %{
        "phases" => [
          "tool.planning",
          "tool.result_interpreting",
          "tool.loop_governing",
          "receipt.finalized"
        ],
        "can_static_analyze" => language != "opaque",
        "can_generate_scenarios" => true,
        "can_explain_trace" => true,
        "can_emit_source_spans" => Enum.any?(tool_rules, &is_map(&1["source_span"]))
      }
    }
  end

  defp engine("ambiguous-success", _config) do
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

  defp engine(_pattern_id, _config) do
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

  defp phases("route-privacy", config) do
    nodes =
      config
      |> route_governance_rules()
      |> Enum.map(&request_governance_node/1)
      |> case do
        [] -> [no_route_gate_node()]
        configured -> configured
      end

    [
      %{
        "id" => "route.selecting",
        "title" => "Route",
        "description" => "Project configured request governance before provider selection.",
        "nodes" => nodes
      }
    ]
  end

  defp phases("tool-governance", config) do
    rules = tool_governance_rules(config)

    planning_nodes =
      rules
      |> Enum.filter(&tool_planning_rule?/1)
      |> Enum.map(&tool_governance_node(&1, "tool.planning"))
      |> case do
        [] -> [no_tool_policy_node("tool.planning", "planning")]
        configured -> configured
      end

    result_nodes =
      rules
      |> Enum.filter(&tool_result_rule?/1)
      |> Enum.map(&tool_governance_node(&1, "tool.result_interpreting"))
      |> case do
        [] -> [no_tool_policy_node("tool.result_interpreting", "result")]
        configured -> configured
      end

    loop_nodes =
      rules
      |> Enum.filter(&tool_loop_rule?/1)
      |> Enum.map(&tool_governance_node(&1, "tool.loop_governing"))
      |> case do
        [] -> [no_tool_policy_node("tool.loop_governing", "loop")]
        configured -> configured
      end

    [
      %{
        "id" => "tool.planning",
        "title" => "Tool Planning",
        "description" =>
          "Review declared tools, explicit tool_choice, and planned assistant tool calls.",
        "nodes" => planning_nodes
      },
      %{
        "id" => "tool.result_interpreting",
        "title" => "Tool Results",
        "description" =>
          "Review tool result status and hashed result evidence before the model interprets it.",
        "nodes" => result_nodes
      },
      %{
        "id" => "tool.loop_governing",
        "title" => "Tool Loop",
        "description" =>
          "Review repeated tool use over session history and configured loop budgets.",
        "nodes" => loop_nodes
      },
      %{
        "id" => "receipt.finalized",
        "title" => "Receipt",
        "description" =>
          "Persist normalized tool context dimensions without raw arguments or raw results.",
        "nodes" => [
          node(
            "tool.receipt-context",
            "tool receipt context",
            "receipt_rule",
            "receipt.finalized",
            "Record namespace, name, phase, risk class, provenance, call id, and hashes for audit/search.",
            "exact",
            ["decision.tool_context"],
            ["receipt.decision.tool_context", "receipt.summary.tool_*"],
            ["annotate_receipt"]
          )
        ]
      }
    ]
  end

  defp phases("stream-rewrite-state", _config) do
    [
      %{
        "id" => "request.preparing",
        "title" => "Request",
        "description" => "Rewrite or remove request-side spans before the provider sees them.",
        "nodes" => [
          node(
            "request.rewrite-context",
            "context redactor",
            "primitive",
            "request.preparing",
            "Remove private context spans from the model-facing prompt while keeping receipt evidence.",
            "exact",
            ["request.messages", "policy_cache.session.regex_match"],
            ["request.model_input", "policy.events"],
            ["match_regex", "rewrite_span"]
          )
        ]
      },
      %{
        "id" => "response.streaming",
        "title" => "Stream",
        "description" =>
          "Evaluate related regex matches over held chunks before bytes are released.",
        "nodes" => [
          node(
            "stream.redact-account",
            "account redactor",
            "primitive",
            "response.streaming",
            "Rewrite account-like spans inside the holdback window before release.",
            "exact",
            ["stream.window", "policy_cache.session.regex_match"],
            ["stream.rewrite_patch", "policy.events"],
            ["match_regex", "rewrite_span"]
          ),
          node(
            "stream.secret-transition",
            "secret transition",
            "primitive",
            "response.streaming",
            "Escalate if a related secret-token pattern appears after the account rewrite.",
            "exact",
            ["stream.window", "policy_cache.session.regex_match"],
            ["policy.state", "final.status"],
            ["match_regex", "state_transition"]
          ),
          node(
            "stream.rewrite-arbiter",
            "rewrite arbiter",
            "arbiter",
            "response.streaming",
            "Applies rewrite patches while preserving enough held context to detect related later matches.",
            "declared",
            ["stream.rewrite_patch", "policy.state"],
            ["stream.release_decision", "request.review_required"],
            ["release_rewritten", "hold_for_review"]
          )
        ]
      },
      %{
        "id" => "receipt.finalized",
        "title" => "Receipt",
        "description" => "Persist rewrite, transition, and review evidence.",
        "nodes" => [
          node(
            "stream.rewrite-receipt",
            "rewrite receipt",
            "receipt_rule",
            "receipt.finalized",
            "Record regex matches, applied rewrite ranges, state transition, and withheld bytes hash.",
            "exact",
            ["policy.events", "stream.rewrite_patch", "policy.state"],
            ["receipt.events"],
            ["annotate_receipt"]
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
    %Contract.Node{
      id: id,
      label: label,
      node_class: kind,
      phase: phase,
      summary: summary,
      confidence: confidence,
      reads: reads,
      writes: writes,
      actions: actions,
      annotations: node_annotations(kind, actions, confidence),
      source_span: source_span
    }
    |> Contract.to_map()
  end

  defp node_annotations("plan_gap", _actions, _confidence) do
    %Contract.Annotation{
      why: "This marks an explicit gap where no configured rule currently applies.",
      change_when: "Add or import a recipe when this gap represents a real governance need.",
      review_hint: "Safe as a reminder, but unsafe if operators assume enforcement is active."
    }
  end

  defp node_annotations(_kind, [], "opaque") do
    %Contract.Annotation{
      why:
        "This part exists because the projection could not reduce the policy into exact primitives.",
      change_when:
        "Replace opaque policy code with declared primitives when visual review matters.",
      review_hint: "Treat simulation evidence as required before trusting this branch."
    }
  end

  defp node_annotations(_kind, [], confidence) do
    %Contract.Annotation{
      why: "This node records evidence or context used by nearby policy decisions.",
      change_when:
        "Review when the policy needs different evidence, receipt fields, or routing context.",
      review_hint:
        "Confidence is #{confidence}; inspect reads and writes before changing this rule."
    }
  end

  defp node_annotations(_kind, actions, confidence) do
    %Contract.Annotation{
      why: "This node explains when Wardwright may #{Enum.join(actions, ", ")}.",
      change_when:
        "Review when provider behavior, tool permissions, route costs, or policy intent changes.",
      review_hint:
        "Confidence is #{confidence}; inspect reads and writes before changing this rule."
    }
  end

  defp compiled_plan(pattern_id, config, phases) do
    %{
      "planner" => "Wardwright.Policy.Plan",
      "pattern_id" => pattern_id,
      "request_rule_count" => length(Map.get(config, "governance", [])),
      "stream_rule_count" => length(Map.get(config, "stream_rules", [])),
      "node_count" => phases |> Enum.flat_map(& &1["nodes"]) |> length(),
      "source" => "current_config"
    }
  end

  defp state_machine("tts-retry", phases, config) do
    states = [
      state(
        "observing",
        "Observing",
        "Hold unreleased stream chunks while matching configured stream rules.",
        ["tts.no-old-client"]
      ),
      state(
        "guarding",
        "Guarding",
        "A prohibited span has matched before release; current attempt must stop.",
        ["tts.no-old-client", "tts.retry-arbiter"]
      ),
      state(
        "retrying",
        "Retrying",
        "Retry arbitration adds a reminder or resolves repeat violation to final block.",
        ["tts.retry-arbiter"]
      ),
      state(
        "recording",
        "Recording",
        "Receipt facts persist the held bytes, match, abort, retry, and final status.",
        ["tts.receipt-events"],
        terminal: true
      )
    ]

    %Contract.StateMachine{
      initial_state: "observing",
      default_projection: false,
      summary:
        "Explicit retry loop projection for stream guard, abort, retry, and receipt recording.",
      states: states,
      transitions: [
        transition(
          "stream.match",
          "observing",
          "guarding",
          "stream window matches a prohibited span",
          "abort_attempt",
          "tts.no-old-client"
        ),
        transition(
          "attempt.retry",
          "guarding",
          "retrying",
          "retry budget remains",
          "retry_with_reminder",
          "tts.retry-arbiter"
        ),
        transition(
          "receipt.write",
          "retrying",
          "recording",
          "attempt outcome is known",
          "annotate_receipt",
          "tts.receipt-events"
        )
      ],
      simulation_steps: simulation_steps("tts-retry", config, states)
    }
    |> Contract.to_map()
    |> attach_state_node_fallback(phases)
  end

  defp state_machine("stream-rewrite-state", phases, config) do
    states = [
      state(
        "observing",
        "Observing",
        "Rewrite request-side private context, then hold chunks and scan for related regex matches.",
        ["request.rewrite-context", "stream.redact-account"]
      ),
      state(
        "rewriting",
        "Rewriting",
        "A safe rewrite patch is available but more related stream context is still held.",
        ["stream.redact-account", "stream.rewrite-arbiter"]
      ),
      state(
        "review_required",
        "Review Required",
        "A later related secret-token match prevents normal release.",
        ["stream.secret-transition", "stream.rewrite-arbiter"]
      ),
      state(
        "recording",
        "Recording",
        "Persist rewrite and transition evidence for review and regression fixtures.",
        ["stream.rewrite-receipt"],
        terminal: true
      )
    ]

    %Contract.StateMachine{
      initial_state: "observing",
      default_projection: false,
      summary:
        "Explicit projection for related stream regex matches, rewrite, state transition, and receipt recording.",
      states: states,
      transitions: [
        transition(
          "request.rewrite",
          "observing",
          "observing",
          "private context is removed before provider dispatch",
          "rewrite_span",
          "request.rewrite-context"
        ),
        transition(
          "regex.rewrite",
          "observing",
          "rewriting",
          "account-like regex match is safe to rewrite",
          "rewrite_span",
          "stream.redact-account"
        ),
        transition(
          "regex.related-secret",
          "rewriting",
          "review_required",
          "related secret-token regex appears after a rewrite",
          "state_transition",
          "stream.secret-transition"
        ),
        transition(
          "receipt.write",
          "review_required",
          "recording",
          "review outcome is known",
          "annotate_receipt",
          "stream.rewrite-receipt"
        )
      ],
      simulation_steps: simulation_steps("stream-rewrite-state", config, states)
    }
    |> Contract.to_map()
    |> attach_state_node_fallback(phases)
  end

  defp state_machine(pattern_id, phases, config) do
    states = [
      state(
        "active",
        "Active",
        "Evaluate configured phases without a separate user-authored state model.",
        phase_node_ids(phases)
      )
    ]

    %Contract.StateMachine{
      initial_state: "active",
      default_projection: true,
      summary:
        "Default one-state projection for policies without explicit stateful control flow.",
      states: states,
      transitions: [],
      simulation_steps: simulation_steps(pattern_id, config, states)
    }
    |> Contract.to_map()
  end

  defp attach_state_node_fallback(state_machine, phases) do
    known_node_ids = phase_node_ids(phases) |> MapSet.new()

    states =
      state_machine["states"]
      |> Enum.map(fn state ->
        node_ids = Enum.filter(state["node_ids"], &MapSet.member?(known_node_ids, &1))
        Map.put(state, "node_ids", node_ids)
      end)

    Map.put(state_machine, "states", states)
  end

  defp state(id, label, summary, node_ids, opts \\ []) do
    %Contract.State{
      id: id,
      label: label,
      summary: summary,
      node_ids: node_ids,
      terminal: Keyword.get(opts, :terminal, false)
    }
  end

  defp transition(id, from, to, trigger, action, node_id) do
    %Contract.Transition{
      id: id,
      from: from,
      to: to,
      trigger: trigger,
      action: action,
      node_id: node_id
    }
  end

  defp simulation_steps(pattern_id, config, states) do
    pattern_id
    |> simulation_records(config)
    |> List.first(%{})
    |> Map.get("trace", [])
    |> Enum.with_index(1)
    |> Enum.map(fn {event, index} ->
      state_id = trace_state(event, states)

      %Contract.StateStep{
        step: index,
        state: state_id,
        event_id: event["id"],
        node_id: event["node_id"],
        summary: event["label"],
        severity: event["severity"]
      }
    end)
  end

  defp trace_state(%{"state_id" => state_id}, states)
       when is_binary(state_id) and state_id != "" do
    if Enum.any?(states, &(&1.id == state_id)) do
      state_id
    else
      raise ArgumentError,
            "simulation trace references unknown state_id #{inspect(state_id)}"
    end
  end

  defp trace_state(%{"node_id" => node_id}, states) when is_binary(node_id) do
    states
    |> Enum.find(first_state(states), fn state -> node_id in state.node_ids end)
    |> Map.fetch!(:id)
  end

  defp trace_state(_event, states), do: first_state(states).id

  defp first_state([state | _states]), do: state

  defp phase_node_ids(phases) do
    phases
    |> Enum.flat_map(& &1["nodes"])
    |> Enum.map(& &1["id"])
  end

  defp route_governance_rules(config) do
    config
    |> Map.get("governance", [])
    |> Enum.filter(fn rule ->
      action = Map.get(rule, "action")
      kind = Map.get(rule, "kind")

      kind == "route_gate" or action in ["restrict_routes", "switch_model", "reroute"] or
        Map.get(rule, "engine") in ["starlark", "dune", "wasm", "hybrid"]
    end)
  end

  defp tool_governance_rules(config) do
    config
    |> Map.get("governance", [])
    |> Enum.filter(fn rule ->
      kind = Map.get(rule, "kind")
      phase = Map.get(rule, "phase")

      kind in [
        "tool_selector",
        "tool_allowlist",
        "tool_denylist",
        "tool_loop_threshold",
        @tool_sequence_kind,
        "tool_result_guard"
      ] or
        phase in [
          "tool.planning",
          "tool.result_interpreting",
          "tool.loop_governing",
          "tool.using"
        ]
    end)
  end

  defp tool_planning_rule?(rule) do
    Map.get(rule, "kind") in ["tool_selector", "tool_allowlist", "tool_denylist"] or
      Map.get(rule, "phase") in ["tool.planning", "tool.using"]
  end

  defp tool_result_rule?(rule) do
    Map.get(rule, "kind") == "tool_result_guard" or
      Map.get(rule, "phase") == "tool.result_interpreting"
  end

  defp tool_loop_rule?(rule) do
    Map.get(rule, @kind_key) in [@tool_loop_threshold_kind, @tool_sequence_kind] or
      Map.get(rule, "phase") == "tool.loop_governing"
  end

  defp route_engine_language([]), do: "structured"

  defp route_engine_language(rules) do
    rules
    |> Enum.map(&Map.get(&1, "engine"))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> case do
      [] -> "structured"
      [language] -> language
      _many -> "hybrid"
    end
  end

  defp request_governance_node(rule) do
    action = request_governance_action(rule)
    action_name = Map.get(action, "action", "annotate")

    node(
      "request-policy.#{safe_id(Map.get(rule, "id", action_name))}",
      Map.get(rule, "label", Map.get(rule, "id", action_name)),
      request_governance_kind(rule),
      "route.selecting",
      request_governance_summary(rule, action),
      request_governance_confidence(rule),
      request_governance_reads(rule),
      request_governance_writes(action),
      [action_name],
      Map.get(rule, "source_span")
    )
  end

  defp request_governance_action(rule) do
    %{
      "rule_id" => Map.get(rule, "id", "route-policy"),
      "kind" => Map.get(rule, "kind", "route_gate"),
      "action" => Map.get(rule, "action", default_projected_action(rule)),
      "message" => Map.get(rule, "message", "route governance rule"),
      "allowed_targets" => Map.get(rule, "allowed_targets"),
      "target_model" => Map.get(rule, "target_model", Map.get(rule, "model")),
      "allow_fallback" => Map.get(rule, "allow_fallback")
    }
    |> Wardwright.Policy.Action.normalize(rule: rule)
  end

  defp default_projected_action(%{"engine" => engine}) when engine not in [nil, ""],
    do: "engine_result"

  defp default_projected_action(_rule), do: "restrict_routes"

  defp request_governance_kind(%{"engine" => engine}) when engine not in [nil, ""],
    do: "policy_engine"

  defp request_governance_kind(rule), do: Map.get(rule, "kind", "route_gate")

  defp request_governance_summary(rule, action) do
    message = Map.get(rule, "message", Map.get(action, "message", "route governance rule"))
    "#{Map.get(action, "action", "annotate")} when #{rule_match_summary(rule)}: #{message}"
  end

  defp rule_match_summary(rule) do
    cond do
      is_binary(rule["contains"]) and rule["contains"] != "" ->
        "request contains #{inspect(rule["contains"])}"

      is_binary(rule["regex"]) and rule["regex"] != "" ->
        "request matches #{inspect(rule["regex"])}"

      is_binary(rule["pattern"]) and rule["pattern"] != "" ->
        "request contains #{inspect(rule["pattern"])}"

      true ->
        "rule matches"
    end
  end

  defp request_governance_confidence(%{"engine" => engine}) when engine not in [nil, ""] do
    if is_map(engine) or engine == "hybrid", do: "inferred", else: "opaque"
  end

  defp request_governance_confidence(_rule), do: "exact"

  defp request_governance_reads(%{"kind" => "history_threshold"}),
    do: ["request.messages", "policy_cache.session"]

  defp request_governance_reads(%{"kind" => "history_regex_threshold"}),
    do: ["request.messages", "policy_cache.session"]

  defp request_governance_reads(_rule), do: ["request.messages", "caller", "route.candidates"]

  defp request_governance_writes(%{"action" => "restrict_routes"}), do: ["route.allowed_targets"]

  defp request_governance_writes(%{"action" => action})
       when action in ["switch_model", "reroute"], do: ["route.forced_model"]

  defp request_governance_writes(%{"action" => "block"}), do: ["decision.blocked"]
  defp request_governance_writes(_action), do: ["policy.actions"]

  defp no_route_gate_node do
    node(
      "request-policy.no-route-gate",
      "no route gate configured",
      "plan_gap",
      "route.selecting",
      "No route-affecting governance rule is present in the active configuration.",
      "exact",
      ["governance"],
      [],
      []
    )
  end

  defp tool_governance_node(rule, phase) do
    id = Map.get(rule, "id", Map.get(rule, "kind", "tool-policy"))
    action = Map.get(rule, "action", default_tool_action(rule))

    node(
      "tool-policy.#{safe_id(id)}",
      Map.get(rule, "label", id),
      Map.get(rule, "kind", "tool_policy"),
      phase,
      tool_governance_summary(rule, action),
      tool_governance_confidence(rule),
      tool_governance_reads(rule, phase),
      tool_governance_writes(action),
      [action],
      Map.get(rule, "source_span")
    )
  end

  defp default_tool_action(%{"kind" => "tool_loop_threshold"}), do: "fail_closed"

  defp default_tool_action(%{@kind_key => @tool_sequence_kind, @transition_to_key => _state}),
    do: @state_transition_action

  defp default_tool_action(%{
         @kind_key => @tool_sequence_kind,
         @then_key => %{@action_key => action}
       }),
       do: action

  defp default_tool_action(%{"kind" => "tool_result_guard"}), do: "review_result"
  defp default_tool_action(%{"kind" => "tool_denylist"}), do: "deny_tool"
  defp default_tool_action(_rule), do: "constrain_tools"

  defp tool_governance_summary(rule, action) do
    "#{action} when #{tool_match_summary(rule)}"
  end

  defp tool_match_summary(rule) do
    tool = Map.get(rule, "tool", %{})

    matcher =
      [
        {"namespace", Map.get(rule, "namespace", Map.get(tool, "namespace"))},
        {"name", Map.get(rule, "name", Map.get(tool, "name"))},
        {"risk_class", Map.get(rule, "risk_class", Map.get(tool, "risk_class"))},
        {"phase", Map.get(rule, "phase", Map.get(tool, "phase"))}
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)
      |> Enum.join(", ")

    cond do
      matcher != "" -> matcher
      is_integer(Map.get(rule, "threshold")) -> "tool count >= #{Map.get(rule, "threshold")}"
      true -> "tool context matches"
    end
  end

  defp tool_governance_confidence(%{"engine" => engine}) when engine not in [nil, ""] do
    if is_map(engine) or engine == "hybrid", do: "inferred", else: "opaque"
  end

  defp tool_governance_confidence(_rule), do: "declared"

  defp tool_governance_reads(%{"kind" => "tool_loop_threshold"}, _phase),
    do: ["decision.tool_context", "policy_cache.session.tool_call"]

  defp tool_governance_reads(%{@kind_key => @tool_sequence_kind}, _phase),
    do: [
      @decision_tool_context_read,
      @policy_cache_tool_call_read,
      @policy_cache_state_read
    ]

  defp tool_governance_reads(_rule, "tool.result_interpreting"),
    do: ["decision.tool_context", "tool.result_hash", "tool.result_status"]

  defp tool_governance_reads(_rule, _phase),
    do: ["request.tools", "request.tool_choice", "message.tool_calls", "decision.tool_context"]

  defp tool_governance_writes("deny_tool"), do: ["decision.blocked", "tool.allowed"]
  defp tool_governance_writes("fail_closed"), do: ["decision.blocked", "final.status"]
  defp tool_governance_writes("review_result"), do: ["policy.actions", "receipt.events"]

  defp tool_governance_writes(@state_transition_action),
    do: [@policy_actions_write, @policy_cache_state_read]

  defp tool_governance_writes(_action), do: ["tool.allowed", "policy.actions"]

  defp no_tool_policy_node(phase, label) do
    node(
      "tool-policy.no-#{safe_id(label)}-policy",
      "no #{label} tool policy",
      "plan_gap",
      phase,
      "No #{label} tool-governance rule is present in the active configuration.",
      "exact",
      ["governance", "decision.tool_context"],
      [],
      []
    )
  end

  defp stream_summary([]), do: "Match prohibited output inside the unreleased stream horizon."

  defp stream_summary(rules) do
    ids =
      rules
      |> Enum.map(&Map.get(&1, "id", "stream-rule"))
      |> Enum.join(", ")

    "Project configured stream rules into a holdback detector: #{ids}."
  end

  defp safe_id(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "policy"
      safe -> safe
    end
  end

  defp effects("ambiguous-success", _config) do
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

  defp effects("route-privacy", config) do
    config
    |> route_governance_rules()
    |> Enum.map(&request_governance_action/1)
    |> Enum.with_index()
    |> Enum.map(fn {action, index} ->
      effect(
        "effect.route-policy-#{index + 1}",
        "request-policy.#{safe_id(Map.get(action, "rule_id", "route-policy"))}",
        "route.selecting",
        Map.get(action, "action", "annotate"),
        route_effect_target(action),
        Map.get(action, "source", %{}) |> Map.get("type") |> effect_confidence()
      )
    end)
  end

  defp effects("tool-governance", config) do
    rules = tool_governance_rules(config)

    effects =
      rules
      |> Enum.map(fn rule ->
        action = Map.get(rule, "action", default_tool_action(rule))

        effect(
          "effect.tool-policy-#{safe_id(Map.get(rule, "id", action))}",
          "tool-policy.#{safe_id(Map.get(rule, "id", action))}",
          tool_rule_phase(rule),
          action,
          tool_effect_target(action),
          tool_governance_confidence(rule)
        )
      end)

    effects ++
      [
        effect(
          "effect.tool-receipt",
          "tool.receipt-context",
          "receipt.finalized",
          "annotate_receipt",
          "receipt",
          "exact"
        )
      ]
  end

  defp effects("stream-rewrite-state", _config) do
    [
      effect(
        "effect.request-rewrite",
        "request.rewrite-context",
        "request.preparing",
        "rewrite_span",
        "request",
        "exact"
      ),
      effect(
        "effect.stream-rewrite",
        "stream.redact-account",
        "response.streaming",
        "rewrite_span",
        "stream",
        "exact"
      ),
      effect(
        "effect.stream-transition",
        "stream.secret-transition",
        "response.streaming",
        "state_transition",
        "policy_state",
        "exact"
      ),
      effect(
        "effect.stream-review",
        "stream.rewrite-arbiter",
        "response.streaming",
        "hold_for_review",
        "request",
        "declared"
      ),
      effect(
        "effect.stream-receipt",
        "stream.rewrite-receipt",
        "receipt.finalized",
        "annotate_receipt",
        "receipt",
        "exact"
      )
    ]
  end

  defp effects(_pattern_id, _config) do
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

  defp route_effect_target(%{"action" => "restrict_routes"}), do: "route"

  defp route_effect_target(%{"action" => action}) when action in ["switch_model", "reroute"],
    do: "route"

  defp route_effect_target(%{"action" => "block"}), do: "request"
  defp route_effect_target(_action), do: "policy"

  defp tool_rule_phase(rule) do
    cond do
      tool_loop_rule?(rule) -> "tool.loop_governing"
      tool_result_rule?(rule) -> "tool.result_interpreting"
      true -> "tool.planning"
    end
  end

  defp tool_effect_target(action) when action in ["deny_tool", "constrain_tools"], do: "tool"
  defp tool_effect_target(action) when action in ["fail_closed", "block"], do: "request"
  defp tool_effect_target(_action), do: "policy"

  defp effect_confidence("primitive"), do: "exact"
  defp effect_confidence(_source_type), do: "inferred"

  defp effect(id, node_id, phase, effect, target, confidence) do
    %Contract.Effect{
      id: id,
      node_id: node_id,
      phase: phase,
      effect: effect,
      target: target,
      confidence: confidence
    }
    |> Contract.to_map()
  end

  defp conflicts("ambiguous-success", _config) do
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

  defp conflicts("route-privacy", config) do
    config
    |> route_governance_rules()
    |> Enum.map(&request_governance_action/1)
    |> Wardwright.Policy.Action.conflicts()
    |> Enum.map(fn conflict ->
      rule_ids = Map.get(conflict, "rule_ids", [])

      %{
        "id" => "conflict.#{Map.get(conflict, "key", "policy")}",
        "class" => Map.get(conflict, "class", "ordered"),
        "node_ids" => Enum.map(rule_ids, &"request-policy.#{safe_id(&1)}"),
        "summary" => Map.get(conflict, "summary"),
        "required_resolution" => Map.get(conflict, "required_resolution")
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
      |> Map.new()
    end)
  end

  defp conflicts("tool-governance", config) do
    config
    |> tool_governance_rules()
    |> Enum.group_by(&tool_rule_phase/1)
    |> Enum.flat_map(fn {phase, rules} ->
      if length(rules) > 1 do
        [
          %{
            "id" => "conflict.tool-policy.#{safe_id(phase)}",
            "class" => "ordered",
            "node_ids" =>
              Enum.map(rules, &"tool-policy.#{safe_id(Map.get(&1, "id", "tool-policy"))}"),
            "summary" =>
              "Multiple tool-governance rules can affect #{phase}; activation needs explicit priority or proof that actions do not conflict.",
            "required_resolution" =>
              "declare priority, mutual exclusivity, or an allow/deny precedence contract before enforcement"
          }
        ]
      else
        []
      end
    end)
  end

  defp conflicts("stream-rewrite-state", _config) do
    [
      %{
        "id" => "conflict.rewrite-before-transition",
        "class" => "ordered",
        "node_ids" => ["stream.redact-account", "stream.secret-transition"],
        "summary" =>
          "The safe rewrite may run, but a later related secret-token match can still force review before release.",
        "required_resolution" =>
          "preserve enough held context after rewriting to evaluate related transition rules"
      }
    ]
  end

  defp conflicts(_pattern_id, _config) do
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

  defp opaque_regions("route-privacy", config) do
    config
    |> route_governance_rules()
    |> Enum.filter(fn rule -> request_governance_confidence(rule) == "opaque" end)
    |> Enum.map(fn rule ->
      %{
        "id" => "opaque.#{safe_id(Map.get(rule, "id", "route-policy"))}",
        "node_id" => "request-policy.#{safe_id(Map.get(rule, "id", "route-policy"))}",
        "reason" =>
          "Sandboxed route policy is represented through its action contract; static adapter cannot prove every internal branch.",
        "review_requirement" =>
          "Require scenario coverage for route denial, allowed fallback, and no-match cases."
      }
    end)
  end

  defp opaque_regions("tool-governance", config) do
    config
    |> tool_governance_rules()
    |> Enum.filter(fn rule -> tool_governance_confidence(rule) == "opaque" end)
    |> Enum.map(fn rule ->
      %{
        "id" => "opaque.#{safe_id(Map.get(rule, "id", "tool-policy"))}",
        "node_id" => "tool-policy.#{safe_id(Map.get(rule, "id", "tool-policy"))}",
        "reason" =>
          "Sandboxed tool policy is represented through its declared action contract; static adapter cannot prove every internal branch.",
        "review_requirement" =>
          "Require scenario coverage for allow, deny, loop-threshold, and result-status cases before activation."
      }
    end)
  end

  defp opaque_regions(_pattern_id, _config), do: []

  defp warnings("route-privacy", config) do
    if route_governance_rules(config) == [] do
      ["No route-affecting governance rule is configured for this projection."]
    else
      []
    end
  end

  defp warnings("tool-governance", config) do
    if tool_governance_rules(config) == [] do
      [
        "Tool context is normalized and recorded, but no tool-governance rule is configured for enforcement."
      ]
    else
      [
        "Tool-context provenance is evidence only; caller-provided metadata must not be treated as trusted execution fact."
      ]
    end
  end

  defp warnings("ambiguous-success", _config) do
    [
      "Classifier wording can drift; pin generated false-positive examples as regression fixtures."
    ]
  end

  defp warnings(_pattern_id, _config),
    do: ["Adds stream latency up to the configured holdback horizon."]

  defp simulation_records(pattern_id, config) do
    case Wardwright.PolicyScenarioStore.list(pattern_id) do
      [] -> simulation_cases(pattern_id, config)
      scenarios -> Enum.map(scenarios, &Wardwright.PolicyScenario.to_map/1)
    end
  end

  defp simulation_cases("ambiguous-success", config),
    do: ambiguous_success_simulation_cases(config)

  defp simulation_cases("route-privacy", config), do: route_privacy_simulation_cases(config)
  defp simulation_cases("tool-governance", config), do: tool_governance_simulation_cases(config)

  defp simulation_cases("stream-rewrite-state", config),
    do: stream_rewrite_simulation_cases(config)

  defp simulation_cases(pattern_id, config), do: default_simulation_cases(pattern_id, config)

  defp evaluated_simulation("ambiguous-success", turn, config),
    do: evaluated_ambiguous_success_simulation(turn, config)

  defp evaluated_simulation("stream-rewrite-state", turn, config),
    do: evaluated_stream_rewrite_simulation(turn, config)

  defp evaluated_simulation("tts-retry", turn, config),
    do: evaluated_tts_retry_simulation(turn, config)

  defp evaluated_simulation(pattern_id, _turn, config) do
    pattern_id
    |> simulations(config)
    |> List.first()
  end

  defp ambiguous_success_simulation_cases(_config) do
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
      |> fixture_case()
    ]
  end

  defp evaluated_ambiguous_success_simulation(turn, _config) do
    text = turn_response(turn)
    has_claim? = Regex.match?(~r/\b(done|ready|completed|finished|export)\b/i, text)
    has_artifact? = Regex.match?(~r/\b(artifact|attachment|download_id|file_id):\s*\S+/i, text)

    if has_claim? and not has_artifact? do
      %{
        "simulation_schema" => "wardwright.policy_simulation.v1",
        "scenario_id" => "interactive-ambiguous-success-alert",
        "title" => "Edited input triggers missing artifact alert",
        "engine_id" => "hybrid-output-review",
        "input_summary" => summarize_turn(turn),
        "expected_behavior" =>
          "Completion language without artifact evidence emits an operator alert.",
        "verdict" => "passed",
        "trace" => [
          trace(
            "i1",
            "output.finalizing",
            "success.claim-detector",
            "match",
            "claim detected",
            "edited final text contains completion language",
            "warn"
          ),
          trace(
            "i2",
            "output.finalizing",
            "success.artifact-check",
            "state_read",
            "metadata missing",
            "no artifact marker was found in the edited input",
            "warn"
          ),
          trace(
            "i3",
            "receipt.finalized",
            "success.artifact-check",
            "action",
            "alert emitted",
            "operator alert and receipt annotation would be recorded",
            "pass"
          )
        ],
        "receipt_preview" => %{
          "input" => turn,
          "events" => [%{"type" => "policy.alert", "rule_id" => "missing-artifact-after-success"}],
          "final_status" => "completed_with_alert"
        }
      }
    else
      %{
        "simulation_schema" => "wardwright.policy_simulation.v1",
        "scenario_id" => "interactive-ambiguous-success-clear",
        "title" => "Edited input clears missing artifact alert",
        "engine_id" => "hybrid-output-review",
        "input_summary" => summarize_turn(turn),
        "expected_behavior" =>
          "No alert is emitted unless completion language lacks artifact evidence.",
        "verdict" => "passed",
        "trace" => [
          trace(
            "i1",
            "output.finalizing",
            "success.claim-detector",
            "input",
            "final text reviewed",
            "edited final text was evaluated for completion language and artifact evidence",
            "info"
          ),
          trace(
            "i2",
            "receipt.finalized",
            "success.artifact-check",
            "receipt_event",
            "no alert",
            "artifact evidence is present or no completion claim was made",
            "pass"
          )
        ],
        "receipt_preview" => %{
          "input" => turn,
          "events" => [],
          "final_status" => "completed"
        }
      }
    end
  end

  defp route_privacy_simulation_cases(config) do
    rules = route_governance_rules(config)

    case rules do
      [] -> no_route_gate_simulation()
      _configured -> [route_governance_simulation(config, rules)]
    end
  end

  defp tool_governance_simulation_cases(config) do
    rules = tool_governance_rules(config)

    case rules do
      [] -> [no_tool_governance_simulation()]
      _configured -> [tool_governance_simulation(rules)]
    end
  end

  defp stream_rewrite_simulation_cases(_config) do
    [
      %{
        "simulation_schema" => "wardwright.policy_simulation.v1",
        "scenario_id" => "rewrite-then-transition",
        "title" => "Rewrite followed by related transition",
        "engine_id" => "structured-stream-primitives",
        "input_summary" =>
          "Provider emits an account identifier, then a related secret token inside the held stream horizon.",
        "expected_behavior" =>
          "Account span is rewritten, later secret-token match transitions to review_required, and no unsafe bytes are released.",
        "verdict" => "passed",
        "trace" => [
          trace(
            "r1",
            "response.streaming",
            "stream.redact-account",
            "input",
            "chunk held",
            "held chunk contains acct_4938 before release",
            "info",
            state_id: "observing"
          ),
          trace(
            "r2",
            "response.streaming",
            "stream.redact-account",
            "match",
            "account regex matched",
            "acct_4938 rewritten to [account-id] inside the holdback window",
            "pass",
            state_id: "rewriting"
          ),
          trace(
            "r3",
            "response.streaming",
            "stream.secret-transition",
            "match",
            "related secret matched",
            "token_ prefix appears after the account rewrite and triggers review_required",
            "block",
            state_id: "review_required"
          ),
          trace(
            "r4",
            "response.streaming",
            "stream.rewrite-arbiter",
            "action",
            "review hold selected",
            "rewritten output remains withheld pending review state resolution",
            "warn",
            state_id: "review_required"
          ),
          trace(
            "r5",
            "receipt.finalized",
            "stream.rewrite-receipt",
            "receipt_event",
            "rewrite receipt",
            "receipt records rewrite range, transition state, and withheld bytes hash",
            "info",
            state_id: "recording"
          )
        ],
        "receipt_preview" => %{
          "receipt_id" => "simulated-rewrite-transition-receipt",
          "stream" => %{
            "rewrites" => [
              %{"rule_id" => "account-redactor", "replacement" => "[account-id]"}
            ],
            "state_transition" => "review_required",
            "released_to_consumer" => false
          },
          "events" => [
            %{"type" => "stream.rewrite_applied", "rule_id" => "account-redactor"},
            %{"type" => "policy.state_transition", "state" => "review_required"},
            %{"type" => "stream.release_blocked", "reason" => "related_secret_match"}
          ]
        }
      }
      |> fixture_case()
    ]
  end

  defp evaluated_stream_rewrite_simulation(turn, _config) do
    text = turn_response(turn)
    account_match = Regex.run(~r/\bacct_[A-Za-z0-9_]+\b/, text)
    secret_match = Regex.run(~r/\b(token|secret)_[A-Za-z0-9_]+\b/i, text)
    related_secret_history_count = related_secret_history_count(turn)
    {model_received_input, request_rewrites} = request_rewrite_result(turn_user_input(turn))
    input_preview = turn_input_preview(turn, model_received_input, request_rewrites)
    request_trace = request_rewrite_trace(request_rewrites)
    history_trace = stream_history_trace(related_secret_history_count)

    cond do
      account_match && (secret_match || related_secret_history_count > 0) ->
        account = hd(account_match)
        secret = if secret_match, do: hd(secret_match), else: "session history"

        secret_detail =
          stream_secret_transition_detail(secret_match, secret, related_secret_history_count)

        %{
          "simulation_schema" => "wardwright.policy_simulation.v1",
          "scenario_id" => "interactive-rewrite-then-transition",
          "title" => "Edited stream rewrites then transitions",
          "engine_id" => "structured-stream-primitives",
          "input_summary" => summarize_turn(turn),
          "expected_behavior" =>
            "Account span is rewritten, a related secret pattern transitions to review_required, and release is blocked.",
          "verdict" => "passed",
          "trace" =>
            request_trace ++
              history_trace ++
              [
                trace(
                  "i1",
                  "response.streaming",
                  "stream.redact-account",
                  "input",
                  "chunk held",
                  "held chunks contain #{account} before release",
                  "info",
                  state_id: "observing"
                ),
                trace(
                  "i2",
                  "response.streaming",
                  "stream.redact-account",
                  "match",
                  "account regex matched",
                  "#{account} rewritten to [account-id] inside the holdback window",
                  "pass",
                  state_id: "rewriting"
                ),
                trace(
                  "i3",
                  "response.streaming",
                  "stream.secret-transition",
                  "match",
                  "related secret matched",
                  secret_detail,
                  "block",
                  state_id: "review_required"
                ),
                trace(
                  "i4",
                  "response.streaming",
                  "stream.rewrite-arbiter",
                  "action",
                  "review hold selected",
                  "rewritten output remains withheld pending review state resolution",
                  "warn",
                  state_id: "review_required"
                ),
                trace(
                  "i5",
                  "receipt.finalized",
                  "stream.rewrite-receipt",
                  "receipt_event",
                  "rewrite receipt",
                  "receipt records rewrite range, transition state, and withheld bytes hash",
                  "info",
                  state_id: "recording"
                )
              ],
          "receipt_preview" => %{
            "input" => input_preview,
            "stream" => %{
              "rewrites" => [
                %{
                  "rule_id" => "account-redactor",
                  "match" => account,
                  "replacement" => "[account-id]"
                }
              ],
              "state_transition" => "review_required",
              "released_to_consumer" => false,
              "history" => %{
                "recent_related_secret_matches" => related_secret_history_count
              }
            },
            "events" => [
              %{"type" => "stream.rewrite_applied", "rule_id" => "account-redactor"},
              %{"type" => "policy.state_transition", "state" => "review_required"},
              %{"type" => "stream.release_blocked", "reason" => "related_secret_match"}
            ]
          }
        }

      account_match ->
        account = hd(account_match)

        %{
          "simulation_schema" => "wardwright.policy_simulation.v1",
          "scenario_id" => "interactive-rewrite-only",
          "title" => "Edited stream rewrites and releases",
          "engine_id" => "structured-stream-primitives",
          "input_summary" => summarize_turn(turn),
          "expected_behavior" =>
            "Account span is rewritten and released because no related secret pattern appears.",
          "verdict" => "passed",
          "trace" =>
            request_trace ++
              history_trace ++
              [
                trace(
                  "i1",
                  "response.streaming",
                  "stream.redact-account",
                  "match",
                  "account regex matched",
                  "#{account} rewritten to [account-id] inside the holdback window",
                  "pass",
                  state_id: "rewriting"
                ),
                trace(
                  "i2",
                  "response.streaming",
                  "stream.rewrite-arbiter",
                  "action",
                  "rewritten stream released",
                  "no related secret pattern appeared before the holdback window closed",
                  "pass",
                  state_id: "rewriting"
                ),
                trace(
                  "i3",
                  "receipt.finalized",
                  "stream.rewrite-receipt",
                  "receipt_event",
                  "rewrite receipt",
                  "receipt records the rewrite without a state transition",
                  "info",
                  state_id: "recording"
                )
              ],
          "receipt_preview" => %{
            "input" => input_preview,
            "stream" => %{
              "rewrites" => [
                %{
                  "rule_id" => "account-redactor",
                  "match" => account,
                  "replacement" => "[account-id]"
                }
              ],
              "state_transition" => nil,
              "released_to_consumer" => true
            },
            "events" => [%{"type" => "stream.rewrite_applied", "rule_id" => "account-redactor"}]
          }
        }

      true ->
        no_stream_rewrite_match_simulation(turn, input_preview, request_trace)
    end
  end

  defp default_simulation_cases(_pattern_id, _config) do
    [
      %{
        "simulation_schema" => "wardwright.policy_simulation.v1",
        "scenario_id" => "split-trigger",
        "title" => "Split trigger before release",
        "engine_id" => "structured-stream-primitives",
        "input_summary" => "Provider emits OldClient( split across held chunks.",
        "expected_behavior" =>
          "No violating bytes from the first attempt are released; the second attempt is generated with a reminder and then released.",
        "verdict" => "passed",
        "trace" => [
          trace(
            "t1",
            "response.streaming",
            "tts.no-old-client",
            "input",
            "chunk held",
            "avoid introducing Old",
            "info",
            state_id: "observing"
          ),
          trace(
            "t2",
            "response.streaming",
            "tts.no-old-client",
            "match",
            "regex matched",
            "Client( completes the prohibited span inside the holdback window",
            "block",
            state_id: "guarding"
          ),
          trace(
            "t3",
            "response.streaming",
            "tts.retry-arbiter",
            "action",
            "retry selected",
            "attempt aborted before release and retry reminder injected",
            "pass",
            state_id: "retrying"
          ),
          trace(
            "t4",
            "response.streaming",
            "tts.no-old-client",
            "output",
            "retry stream released",
            "second model attempt avoids the prohibited span and can be released",
            "pass",
            state_id: "retrying"
          ),
          trace(
            "t5",
            "receipt.finalized",
            "tts.receipt-events",
            "receipt_event",
            "receipt preview",
            "stream.rule_matched, attempt.retry_requested, and final release events recorded",
            "info",
            state_id: "recording"
          )
        ],
        "receipt_preview" => %{
          "receipt_id" => "simulated-policy-receipt",
          "synthetic_model" => Wardwright.synthetic_model(),
          "policy_version" => "draft.ttsr.001",
          "stream" => %{
            "rule_matched" => "no-old-client",
            "released_to_consumer" => true,
            "abort_offset" => 42,
            "retry_attempted" => true,
            "final_output" => "Use the current client adapter in the migration note.",
            "attempts" => [
              %{
                "index" => 1,
                "status" => "withheld_and_aborted",
                "model_output" => "avoid introducing Old\nClient( into the final answer",
                "user_output" => "",
                "policy_result" => "prohibited span matched inside the held horizon"
              },
              %{
                "index" => 2,
                "status" => "released_after_retry",
                "model_output" => "Use the current client adapter in the migration note.",
                "user_output" => "Use the current client adapter in the migration note.",
                "retry_instruction" =>
                  "Do not emit OldClient(. Use current client adapter wording instead.",
                "policy_result" => "retry output passed the stream guard"
              }
            ]
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
            %{"type" => "attempt.retry_requested", "reminder_id" => "no-old-client.reminder"},
            %{"type" => "stream.released", "attempt" => 2, "reason" => "retry_passed_guard"}
          ]
        }
      }
      |> fixture_case()
    ]
  end

  defp evaluated_tts_retry_simulation(turn, _config) do
    text = turn_response(turn)

    if Regex.match?(~r/Old\s*Client\(/, text) do
      %{
        "simulation_schema" => "wardwright.policy_simulation.v1",
        "scenario_id" => "interactive-tts-retry",
        "title" => "Edited stream triggers retry",
        "engine_id" => "structured-stream-primitives",
        "input_summary" => summarize_turn(turn),
        "expected_behavior" =>
          "No violating bytes from the first attempt are released; the second attempt is generated with a reminder and then released.",
        "verdict" => "passed",
        "trace" => [
          trace(
            "i1",
            "response.streaming",
            "tts.no-old-client",
            "input",
            "chunk held",
            "edited chunks are held before release",
            "info",
            state_id: "observing"
          ),
          trace(
            "i2",
            "response.streaming",
            "tts.no-old-client",
            "match",
            "regex matched",
            "Client( completes the prohibited span inside the holdback window",
            "block",
            state_id: "guarding"
          ),
          trace(
            "i3",
            "response.streaming",
            "tts.retry-arbiter",
            "action",
            "retry selected",
            "attempt aborted before release and retry reminder injected",
            "pass",
            state_id: "retrying"
          ),
          trace(
            "i4",
            "response.streaming",
            "tts.no-old-client",
            "output",
            "retry stream released",
            "second model attempt avoids the prohibited span and can be released",
            "pass",
            state_id: "retrying"
          ),
          trace(
            "i5",
            "receipt.finalized",
            "tts.receipt-events",
            "receipt_event",
            "receipt preview",
            "stream.rule_matched, attempt.retry_requested, and final release events recorded",
            "info",
            state_id: "recording"
          )
        ],
        "receipt_preview" => %{
          "input" => turn_input_preview(turn),
          "stream" => %{
            "rule_matched" => "no-old-client",
            "released_to_consumer" => true,
            "retry_attempted" => true,
            "final_output" => tts_retry_final_output(turn),
            "attempts" => [
              %{
                "index" => 1,
                "status" => "withheld_and_aborted",
                "model_output" => text,
                "user_output" => "",
                "policy_result" => "prohibited span matched inside the held horizon"
              },
              %{
                "index" => 2,
                "status" => "released_after_retry",
                "model_output" => tts_retry_final_output(turn),
                "user_output" => tts_retry_final_output(turn),
                "retry_instruction" =>
                  "Do not emit OldClient(. Use current client adapter wording instead.",
                "policy_result" => "retry output passed the stream guard"
              }
            ]
          },
          "events" => [
            %{"type" => "stream.rule_matched", "rule_id" => "no-old-client"},
            %{"type" => "attempt.aborted", "reason" => "tts_rule_matched"},
            %{"type" => "attempt.retry_requested", "reminder_id" => "no-old-client.reminder"},
            %{"type" => "stream.released", "attempt" => 2, "reason" => "retry_passed_guard"}
          ]
        }
      }
    else
      %{
        "simulation_schema" => "wardwright.policy_simulation.v1",
        "scenario_id" => "interactive-tts-safe-release",
        "title" => "Edited stream releases normally",
        "engine_id" => "structured-stream-primitives",
        "input_summary" => summarize_turn(turn),
        "expected_behavior" =>
          "No prohibited span appears inside the holdback window, so the stream can release.",
        "verdict" => "passed",
        "trace" => [
          trace(
            "i1",
            "response.streaming",
            "tts.no-old-client",
            "input",
            "chunk held",
            "edited chunks were scanned without matching OldClient(",
            "info",
            state_id: "observing"
          ),
          trace(
            "i2",
            "receipt.finalized",
            "tts.receipt-events",
            "receipt_event",
            "safe release receipt",
            "receipt records that no retry was requested",
            "pass",
            state_id: "recording"
          )
        ],
        "receipt_preview" => %{
          "input" => turn_input_preview(turn),
          "stream" => %{
            "rule_matched" => nil,
            "released_to_consumer" => true,
            "retry_attempted" => false
          },
          "events" => [%{"type" => "stream.released", "reason" => "no_policy_match"}]
        }
      }
    end
  end

  defp tts_retry_final_output(turn) do
    input = turn_user_input(turn)

    cond do
      String.contains?(input, "migration") ->
        "Use the current client adapter in the migration note."

      String.trim(input) == "" ->
        "Use the current client adapter."

      true ->
        "Use the current client adapter. Avoid deprecated constructor names."
    end
  end

  defp no_stream_rewrite_match_simulation(turn, input_preview, request_trace) do
    %{
      "simulation_schema" => "wardwright.policy_simulation.v1",
      "scenario_id" => "interactive-stream-no-match",
      "title" => "Edited stream has no regex match",
      "engine_id" => "structured-stream-primitives",
      "input_summary" => summarize_turn(turn),
      "expected_behavior" =>
        "No rewrite or state transition is applied because no configured regex matches.",
      "verdict" => "passed",
      "trace" =>
        request_trace ++
          [
            trace(
              "i1",
              "response.streaming",
              "stream.redact-account",
              "input",
              "chunk held",
              "edited chunks were scanned without an account-id match",
              "info",
              state_id: "observing"
            ),
            trace(
              "i2",
              "response.streaming",
              "stream.rewrite-arbiter",
              "action",
              "stream released",
              "no rewrite patch or review transition was produced",
              "pass",
              state_id: "observing"
            ),
            trace(
              "i3",
              "receipt.finalized",
              "stream.rewrite-receipt",
              "receipt_event",
              "no-op receipt",
              "receipt records that the stream was released without policy effects",
              "info",
              state_id: "recording"
            )
          ],
      "receipt_preview" => %{
        "input" => input_preview,
        "stream" => %{
          "rewrites" => [],
          "state_transition" => nil,
          "released_to_consumer" => true
        },
        "events" => [%{"type" => "stream.released", "reason" => "no_policy_match"}]
      }
    }
  end

  defp stream_secret_transition_detail(nil, _secret, related_secret_history_count) do
    "#{related_secret_history_count} prior related secret match(es) in session history trigger review_required after this account rewrite"
  end

  defp stream_secret_transition_detail(_secret_match, secret, _related_secret_history_count) do
    "#{secret} appears after the account rewrite and triggers review_required"
  end

  defp stream_history_trace(0), do: []

  defp stream_history_trace(count) do
    [
      trace(
        "ih",
        "response.streaming",
        "stream.secret-transition",
        "history_read",
        "prior related matches read",
        "#{count} related secret match(es) found in session history",
        "info",
        state_id: "observing"
      )
    ]
  end

  defp request_rewrite_result(user_input) do
    Regex.scan(~r/private_context\{[^}]*\}/i, user_input)
    |> Enum.map(&hd/1)
    |> case do
      [] ->
        {user_input, []}

      matches ->
        model_received_input =
          Enum.reduce(matches, user_input, fn match, input ->
            String.replace(input, match, "[private-context omitted]")
          end)

        rewrites =
          Enum.map(matches, fn match ->
            %{
              "rule_id" => "private-context-redactor",
              "match" => match,
              "replacement" => "[private-context omitted]",
              "direction" => "request"
            }
          end)

        {model_received_input, rewrites}
    end
  end

  defp request_rewrite_trace([]), do: []

  defp request_rewrite_trace(_rewrites) do
    [
      trace(
        "i0",
        "request.preparing",
        "request.rewrite-context",
        "match",
        "request context redacted",
        "private_context{...} was removed before provider dispatch",
        "pass",
        state_id: "observing"
      )
    ]
  end

  defp summarize_turn(turn) do
    user = turn |> turn_user_input() |> String.trim()
    response = turn |> turn_response() |> String.trim()

    cond do
      user != "" and response != "" ->
        "User: #{truncate(user, 80)} / Model: #{truncate(response, 120)}"

      response != "" ->
        truncate(response, 140)

      user != "" ->
        "User: #{truncate(user, 140)}"

      true ->
        "Empty simulated turn."
    end
  end

  defp turn_input_preview(turn), do: turn_input_preview(turn, turn_user_input(turn), [])

  defp turn_input_preview(turn, model_received_input, request_rewrites) do
    %{
      "user_input" => turn_user_input(turn),
      "model_received_input" => model_received_input,
      "request_rewrites" => request_rewrites,
      "history_context" => turn_history_context(turn),
      "model_response" => turn_response(turn),
      "response_chunks" => input_chunks(turn_response(turn))
    }
  end

  defp turn_user_input(%{"user_input" => value}) when is_binary(value), do: value
  defp turn_user_input(_turn), do: ""

  defp turn_response(%{"model_response" => value}) when is_binary(value), do: value
  defp turn_response(%{"text" => value}) when is_binary(value), do: value
  defp turn_response(_turn), do: ""

  defp turn_history_context(%{"history_context" => value}) when is_map(value),
    do: normalize_history_context(value)

  defp turn_history_context(_turn), do: %{}

  defp related_secret_history_count(turn) do
    turn
    |> turn_history_context()
    |> Map.get("recent_related_secret_matches", "0")
    |> parse_nonnegative_integer()
  end

  defp normalize_history_context(context) when is_map(context) do
    context
    |> Enum.reject(fn {key, _value} -> String.starts_with?(to_string(key), "_unused_") end)
    |> Enum.map(fn {key, value} -> {to_string(key), history_context_value(value)} end)
    |> Map.new()
  end

  defp normalize_history_context(_context), do: %{}

  defp history_context_value(value) when is_binary(value), do: value
  defp history_context_value(value) when is_integer(value), do: Integer.to_string(value)
  defp history_context_value(value) when is_float(value), do: Float.to_string(value)
  defp history_context_value(value) when is_boolean(value), do: to_string(value)
  defp history_context_value(nil), do: ""
  defp history_context_value(value), do: inspect(value)

  defp parse_nonnegative_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, _rest} when integer > 0 -> integer
      _ -> 0
    end
  end

  defp parse_nonnegative_integer(value) when is_integer(value) and value > 0, do: value
  defp parse_nonnegative_integer(_value), do: 0

  defp input_chunks(text) do
    text
    |> String.split(~r/\R/, trim: true)
    |> case do
      [] -> [""]
      chunks -> chunks
    end
  end

  defp truncate(text, limit) when byte_size(text) <= limit, do: text

  defp truncate(text, limit) do
    text
    |> binary_part(0, limit)
    |> Kernel.<>("...")
  end

  defp no_route_gate_simulation do
    [
      %{
        "simulation_schema" => "wardwright.policy_simulation.v1",
        "scenario_id" => "no-route-gate-configured",
        "title" => "No route governance configured",
        "engine_id" => "request-route-plan",
        "input_summary" => "Active config has no route-affecting governance rules.",
        "expected_behavior" => "Route selection proceeds without policy constraints.",
        "verdict" => "inconclusive",
        "trace" => [
          trace(
            "p1",
            "route.selecting",
            "request-policy.no-route-gate",
            "warning",
            "no route policy",
            "No configured route-governance node could affect this scenario.",
            "warn"
          )
        ],
        "receipt_preview" => %{
          "decision" => %{"policy_actions" => []},
          "final_status" => "simulated"
        }
      }
      |> fixture_case()
    ]
  end

  defp route_governance_simulation(config, rules) do
    text = route_simulation_text(rules)
    request = %{"messages" => [%{"role" => "user", "content" => text}]}

    {_request, policy} =
      Wardwright.Policy.Plan.evaluate_request(request, %{"source" => "projection"}, config)

    actions = Map.get(policy, "actions", [])

    %{
      "simulation_schema" => "wardwright.policy_simulation.v1",
      "scenario_id" => "configured-route-policy",
      "title" => "Configured route governance path",
      "engine_id" => "request-route-plan",
      "input_summary" => "Synthetic request chosen to exercise the first configured route rule.",
      "expected_behavior" => "Policy.Plan emits route constraints or an explicit no-match trace.",
      "verdict" => if(actions == [], do: "inconclusive", else: "passed"),
      "trace" => route_policy_trace(actions, rules),
      "receipt_preview" => %{
        "decision" => %{
          "policy_actions" => actions,
          "route_constraints" => Map.get(policy, "route_constraints", %{}),
          "policy_conflicts" => Map.get(policy, "conflicts", [])
        },
        "final_status" => "simulated"
      }
    }
    |> fixture_case()
  end

  defp no_tool_governance_simulation do
    %{
      "simulation_schema" => "wardwright.policy_simulation.v1",
      "scenario_id" => "no-tool-policy-configured",
      "title" => "No tool governance configured",
      "engine_id" => "tool-context-plan",
      "input_summary" =>
        "A request includes declared tools, but active config has no tool policy.",
      "expected_behavior" => "Tool context is normalized into receipt evidence only.",
      "verdict" => "inconclusive",
      "trace" => [
        trace(
          "g1",
          "tool.planning",
          "tool-policy.no-planning-policy",
          "warning",
          "no tool policy",
          "No configured tool-governance node can constrain this planned tool call.",
          "warn"
        ),
        trace(
          "g2",
          "receipt.finalized",
          "tool.receipt-context",
          "receipt_event",
          "tool context recorded",
          "Receipt summaries can filter namespace/name/phase/risk/source/call id without raw args.",
          "info"
        )
      ],
      "receipt_preview" => %{
        "decision" => %{
          "tool_context" => %{
            "schema" => "wardwright.tool_context.v1",
            "phase" => "planning",
            "primary_tool" => %{
              "namespace" => "openai.function",
              "name" => "lookup_customer",
              "risk_class" => "unknown",
              "source" => "declared_tool"
            }
          }
        },
        "final_status" => "simulated"
      }
    }
    |> fixture_case()
  end

  defp tool_governance_simulation([rule | _rules]) do
    node_id = "tool-policy.#{safe_id(Map.get(rule, "id", "tool-policy"))}"
    phase = tool_rule_phase(rule)

    %{
      "simulation_schema" => "wardwright.policy_simulation.v1",
      "scenario_id" => "configured-tool-policy",
      "title" => "Configured tool governance path",
      "engine_id" => "tool-context-plan",
      "input_summary" => "Synthetic request chosen to exercise the first configured tool rule.",
      "expected_behavior" =>
        "Projection links normalized tool context to a declared tool policy action.",
      "verdict" => "passed",
      "trace" => [
        trace(
          "g1",
          phase,
          node_id,
          "match",
          Map.get(rule, "action", default_tool_action(rule)),
          tool_governance_summary(rule, Map.get(rule, "action", default_tool_action(rule))),
          "pass"
        ),
        trace(
          "g2",
          "receipt.finalized",
          "tool.receipt-context",
          "receipt_event",
          "tool context recorded",
          "Normalized tool context is available as receipt evidence and receipt-list filters.",
          "info"
        )
      ],
      "receipt_preview" => %{
        "decision" => %{
          "tool_context" => %{
            "schema" => "wardwright.tool_context.v1",
            "phase" => tool_context_phase(phase),
            "primary_tool" => %{
              "namespace" => Map.get(rule, "namespace", "mcp.github"),
              "name" => Map.get(rule, "name", "create_pull_request"),
              "risk_class" => Map.get(rule, "risk_class", "write"),
              "source" => "declared_tool"
            }
          },
          "policy_actions" => [
            %{
              "rule_id" => Map.get(rule, "id"),
              "action" => Map.get(rule, "action", default_tool_action(rule))
            }
          ]
        },
        "final_status" => "simulated"
      }
    }
    |> fixture_case()
  end

  defp fixture_case(simulation) do
    simulation
    |> put_string("scenario_source", "fixture")
    |> put_string("source", "fixture")
  end

  defp tool_context_phase("tool.result_interpreting"), do: "result_interpretation"
  defp tool_context_phase("tool.loop_governing"), do: "loop_governance"
  defp tool_context_phase(phase), do: String.replace_prefix(phase, "tool.", "")

  defp put_string(map, key, value), do: Map.put(map, key, value)

  defp route_simulation_text([rule | _rules]) do
    cond do
      is_binary(rule["contains"]) and rule["contains"] != "" ->
        "projection simulation #{rule["contains"]}"

      is_binary(rule["pattern"]) and rule["pattern"] != "" ->
        "projection simulation #{rule["pattern"]}"

      true ->
        "projection simulation route governance request"
    end
  end

  defp route_policy_trace([], [rule | _rules]) do
    [
      trace(
        "p1",
        "route.selecting",
        "request-policy.#{safe_id(Map.get(rule, "id", "route-policy"))}",
        "warning",
        "rule did not match",
        "The configured policy plan produced no route action for the generated scenario.",
        "warn"
      )
    ]
  end

  defp route_policy_trace(actions, _rules) do
    actions
    |> Enum.with_index()
    |> Enum.map(fn {action, index} ->
      trace(
        "p#{index + 1}",
        "route.selecting",
        "request-policy.#{safe_id(Map.get(action, "rule_id", "route-policy"))}",
        "action",
        Map.get(action, "action", "policy action"),
        Map.get(action, "message", "configured policy action matched"),
        "pass"
      )
    end)
  end

  defp trace(id, phase, node_id, kind, label, detail, severity, opts \\ []) do
    opts = trace_opts(opts)

    %Contract.TraceEvent{
      id: id,
      phase: phase,
      node_id: node_id,
      kind: kind,
      label: label,
      detail: detail,
      severity: severity,
      state_id: Keyword.get(opts, :state_id),
      source_span: Keyword.get(opts, :source_span)
    }
    |> Contract.to_map()
  end

  defp trace_opts(opts) when is_list(opts), do: opts
  defp trace_opts(source_span), do: [source_span: source_span]
end
