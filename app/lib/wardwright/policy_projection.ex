defmodule Wardwright.PolicyProjection do
  @moduledoc false

  alias Wardwright.PolicyProjection.Contract

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
      source_span: source_span
    }
    |> Contract.to_map()
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
    Map.get(rule, "kind") == "tool_loop_threshold" or
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
  defp default_tool_action(%{"kind" => "tool_result_guard"}), do: "review_result"
  defp default_tool_action(%{"kind" => "tool_denylist"}), do: "deny_tool"
  defp default_tool_action(_rule), do: "constrain_tools"

  defp tool_governance_summary(rule, action) do
    "#{action} when #{tool_match_summary(rule)}"
  end

  defp tool_match_summary(rule) do
    matcher =
      [
        {"namespace", Map.get(rule, "namespace")},
        {"name", Map.get(rule, "name")},
        {"risk_class", Map.get(rule, "risk_class")},
        {"phase", Map.get(rule, "phase")}
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

  defp tool_governance_reads(_rule, "tool.result_interpreting"),
    do: ["decision.tool_context", "tool.result_hash", "tool.result_status"]

  defp tool_governance_reads(_rule, _phase),
    do: ["request.tools", "request.tool_choice", "message.tool_calls", "decision.tool_context"]

  defp tool_governance_writes("deny_tool"), do: ["decision.blocked", "tool.allowed"]
  defp tool_governance_writes("fail_closed"), do: ["decision.blocked", "final.status"]
  defp tool_governance_writes("review_result"), do: ["policy.actions", "receipt.events"]
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

  defp simulation_cases("ambiguous-success", _config) do
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

  defp simulation_cases("route-privacy", config) do
    rules = route_governance_rules(config)

    case rules do
      [] -> no_route_gate_simulation()
      _configured -> [route_governance_simulation(config, rules)]
    end
  end

  defp simulation_cases("tool-governance", config) do
    rules = tool_governance_rules(config)

    case rules do
      [] -> [no_tool_governance_simulation()]
      _configured -> [tool_governance_simulation(rules)]
    end
  end

  defp simulation_cases(_pattern_id, _config) do
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
            "receipt.finalized",
            "tts.receipt-events",
            "receipt_event",
            "receipt preview",
            "stream.rule_matched and attempt.retry_requested events recorded",
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
      |> fixture_case()
    ]
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
              "source" => "caller_metadata"
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
