pub type ResultAction {
  Allow
  Block
}

pub fn phase(kind: String, action: String) -> String {
  case action {
    "restrict_routes" | "switch_model" | "reroute" -> "request.routing"
    "inject_reminder_and_retry" | "transform" -> "request.rewrite"
    "escalate" | "alert_async" -> "request.alert"
    "block" -> "request.terminal"
    _ -> history_phase(kind)
  }
}

pub fn effect_type(action: String) -> String {
  case action {
    "block" -> "terminal"
    "restrict_routes" | "switch_model" | "reroute" -> "route_constraint"
    "inject_reminder_and_retry" | "transform" -> "request_transform"
    "escalate" | "alert_async" -> "alert"
    "annotate" -> "annotation"
    _ -> "custom"
  }
}

pub fn conflict_key(action: String) -> String {
  case action {
    "block" -> "terminal_decision"
    "restrict_routes" | "switch_model" | "reroute" -> "route_constraints"
    "inject_reminder_and_retry" | "transform" -> "request_rewrite"
    _ -> ""
  }
}

pub fn conflict_policy(action: String) -> String {
  case conflict_key(action) {
    "" -> "parallel_safe"
    _ -> "ordered"
  }
}

pub fn default_priority(action: String) -> Int {
  case action {
    "block" -> 10
    "restrict_routes" | "switch_model" | "reroute" -> 30
    "inject_reminder_and_retry" | "transform" -> 50
    "escalate" | "alert_async" -> 70
    _ -> 90
  }
}

pub fn result_action(
  status: String,
  has_blocking_action: Bool,
  action_count: Int,
) -> String {
  case classify_result(status, has_blocking_action, action_count) {
    Block -> "block"
    Allow -> "allow"
  }
}

pub fn conflict_summary(key: String, policy: String) -> String {
  case key, policy {
    "route_constraints", "ordered" ->
      "Multiple route-affecting policy actions matched; declaration order resolves the final route constraints."

    "terminal_decision", "ordered" ->
      "Multiple terminal policy actions matched; fail-closed block semantics win."

    _, _ ->
      "Multiple policy actions share "
      <> key
      <> "; resolution policy is "
      <> policy
      <> "."
  }
}

pub fn conflict_resolution(policy: String) -> String {
  case policy {
    "ordered" -> "preserve policy declaration order"
    "parallel_safe" -> ""
    _ -> policy
  }
}

fn history_phase(kind: String) -> String {
  case kind {
    "history_threshold" | "history_regex_threshold" -> "request.history"
    _ -> "request.review"
  }
}

fn classify_result(
  status: String,
  has_blocking_action: Bool,
  _action_count: Int,
) -> ResultAction {
  case status, has_blocking_action {
    "error", _ -> Block
    _, True -> Block
    _, False -> Allow
  }
}
