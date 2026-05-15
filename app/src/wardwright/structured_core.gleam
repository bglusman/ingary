pub type GuardType {
  JsonSyntax
  SchemaValidation
  SemanticValidation
}

pub type LoopOutcome {
  Continue
  ExhaustedGuardBudget
  ExhaustedRuleBudget(String)
}

pub fn guard_action() -> String {
  "retry_with_validation_feedback"
}

pub fn success_status(guard_count: Int) -> String {
  case guard_count {
    0 -> "completed"
    _ -> "completed_after_guard"
  }
}

pub fn guard_rule_id(
  guard_type: GuardType,
  schema_rule_id: String,
  semantic_rule_id: String,
) -> String {
  case guard_type {
    JsonSyntax -> schema_rule_id
    SchemaValidation -> schema_rule_id
    SemanticValidation -> semantic_rule_id
  }
}

pub fn parse_guard_type(raw: String) -> Result(GuardType, Nil) {
  case raw {
    "json_syntax" -> Ok(JsonSyntax)
    "schema_validation" -> Ok(SchemaValidation)
    "semantic_validation" -> Ok(SemanticValidation)
    _ -> Error(Nil)
  }
}

pub fn guard_rule_id_for_string(
  guard_type: String,
  schema_rule_id: String,
  semantic_rule_id: String,
) -> String {
  case parse_guard_type(guard_type) {
    Ok(parsed) -> guard_rule_id(parsed, schema_rule_id, semantic_rule_id)
    Error(_) -> schema_rule_id
  }
}

pub fn loop_outcome(
  rule_id: String,
  rule_failures: Int,
  max_failures_per_rule: Int,
  attempt_count: Int,
  max_attempts: Int,
) -> LoopOutcome {
  case rule_failures >= max_failures_per_rule {
    True -> ExhaustedRuleBudget(rule_id)
    False -> {
      case attempt_count >= max_attempts {
        True -> ExhaustedGuardBudget
        False -> Continue
      }
    }
  }
}

pub fn loop_outcome_status(
  rule_id: String,
  rule_failures: Int,
  max_failures_per_rule: Int,
  attempt_count: Int,
  max_attempts: Int,
) -> String {
  case
    loop_outcome(
      rule_id,
      rule_failures,
      max_failures_per_rule,
      attempt_count,
      max_attempts,
    )
  {
    Continue -> "continue"
    ExhaustedGuardBudget -> "exhausted_guard_budget"
    ExhaustedRuleBudget(_) -> "exhausted_rule_budget"
  }
}
