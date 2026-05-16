pub type ThresholdDecision {
  Triggered(count: Int, threshold: Int)
  NotTriggered(count: Int, threshold: Int)
}

pub fn threshold(value: Int) -> Int {
  clamp_positive(value)
}

pub fn threshold_decision(
  count: Int,
  threshold threshold_value: Int,
) -> ThresholdDecision {
  let bounded_count = clamp_zero(count)
  let bounded_threshold = threshold(threshold_value)

  case bounded_count >= bounded_threshold {
    True -> Triggered(count: bounded_count, threshold: bounded_threshold)
    False -> NotTriggered(count: bounded_count, threshold: bounded_threshold)
  }
}

pub fn threshold_triggered(count: Int, threshold threshold_value: Int) -> Bool {
  case threshold_decision(count, threshold: threshold_value) {
    Triggered(_, _) -> True
    NotTriggered(_, _) -> False
  }
}

pub fn tool_policy_status(action: String) -> String {
  case action {
    "block" -> "blocked"
    "restrict_routes" | "switch_model" | "reroute" -> "rerouted"
    "escalate" | "alert_async" -> "alerted"
    "inject_reminder_and_retry" | "transform" -> "transformed"
    _ -> "allowed"
  }
}

pub fn scope_label(scope: String) -> String {
  case scope {
    "" -> "session"
    "session_id" -> "session"
    "run_id" -> "run"
    _ -> scope
  }
}

pub fn state_scope_matches(
  required_state: String,
  current_state: String,
) -> Bool {
  case required_state {
    "" -> True
    "active" -> current_state == "active"
    _ -> current_state == required_state
  }
}

pub fn sequence_window_limit(has_requested: Bool, requested: Int) -> Int {
  case has_requested {
    True -> max(2, requested + 1)
    False -> 21
  }
}

pub fn within_wall_clock_window(
  has_max_ms: Bool,
  max_ms: Int,
  current_ms: Int,
  prior_ms: Int,
) -> Bool {
  case has_max_ms {
    False -> True
    True -> current_ms - prior_ms <= max_ms
  }
}

pub fn event_after(
  left_created_ms: Int,
  left_sequence: Int,
  right_created_ms: Int,
  right_sequence: Int,
) -> Bool {
  case left_created_ms > right_created_ms {
    True -> True
    False ->
      left_created_ms == right_created_ms && left_sequence > right_sequence
  }
}

fn clamp_positive(value: Int) -> Int {
  case value > 0 {
    True -> value
    False -> 1
  }
}

fn clamp_zero(value: Int) -> Int {
  case value > 0 {
    True -> value
    False -> 0
  }
}

fn max(left: Int, right: Int) -> Int {
  case left > right {
    True -> left
    False -> right
  }
}
