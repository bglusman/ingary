pub fn state_ids(pattern_id: String, known_pattern: Bool) -> List(String) {
  case pattern_id, known_pattern {
    "tts-retry", _ -> ["observing", "guarding", "retrying", "recording"]
    "stream-rewrite-state", _ -> [
      "observing",
      "rewriting",
      "review_required",
      "recording",
    ]
    _, True -> ["active"]
    _, False -> []
  }
}

pub fn route_action(action: String, has_engine: Bool) -> String {
  case action, has_engine {
    "", True -> "engine_decision"
    "", False -> "restrict_routes"
    action, _ -> action
  }
}

pub fn route_confidence(has_engine: Bool) -> String {
  case has_engine {
    True -> "opaque"
    False -> "exact"
  }
}

pub fn route_effect_target(action: String) -> String {
  case action {
    "restrict_routes" -> "route"
    "switch_model" | "reroute" -> "route"
    "block" -> "request"
    _ -> "policy"
  }
}

pub fn tool_action(
  kind: String,
  top_action: String,
  then_action: String,
  transition_to: String,
) -> String {
  case top_action, kind, transition_to, then_action {
    top_action, _, _, _ if top_action != "" -> top_action
    _, "tool_loop_threshold", _, _ -> "fail_closed"
    _, "tool_sequence", transition_to, _ if transition_to != "" ->
      "state_transition"
    _, "tool_sequence", _, then_action if then_action != "" -> then_action
    _, "tool_result_guard", _, _ -> "review_result"
    _, "tool_denylist", _, _ -> "deny_tool"
    _, _, _, _ -> "constrain_tools"
  }
}

pub fn tool_effect_target(action: String) -> String {
  case action {
    "deny_tool" | "constrain_tools" -> "tool"
    "fail_closed" | "block" -> "request"
    _ -> "policy"
  }
}

pub fn tool_context_phase(phase: String) -> String {
  case phase {
    "tool.result_interpreting" -> "result_interpretation"
    "tool.loop_governing" -> "loop_governance"
    "tool.planning" -> "planning"
    _ -> phase
  }
}
