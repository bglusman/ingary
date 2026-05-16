pub fn inferred_phase(
  has_primary_tool: Bool,
  has_available_tools: Bool,
  has_tool_result: Bool,
) -> String {
  case has_tool_result, has_primary_tool || has_available_tools {
    True, _ -> "result_interpretation"
    False, True -> "planning"
    False, False -> ""
  }
}

pub fn inferred_confidence(
  has_chosen_tool: Bool,
  has_assistant_tool: Bool,
  available_tool_count: Int,
  has_tool_result: Bool,
) -> String {
  case
    has_chosen_tool || has_assistant_tool,
    has_tool_result,
    available_tool_count
  {
    True, _, _ -> "exact"
    False, True, _ -> "inferred"
    False, False, 1 -> "declared"
    False, False, _ -> "ambiguous"
  }
}

pub fn result_status(has_tool_result: Bool) -> String {
  case has_tool_result {
    True -> "unknown"
    False -> ""
  }
}

pub fn default_namespace(
  has_explicit_namespace: Bool,
  tool_type: String,
) -> String {
  case has_explicit_namespace, tool_type {
    True, _ -> ""
    False, "function" -> "openai.function"
    False, _ -> "openai.tool"
  }
}

pub fn list_matches(expected: List(String), actual: String) -> Bool {
  case expected, actual {
    [], _ -> True
    _, "" -> False
    _, _ -> contains(expected, actual)
  }
}

fn contains(values: List(String), actual: String) -> Bool {
  case values {
    [] -> False
    [first, ..] if first == actual -> True
    [_first, ..rest] -> contains(rest, actual)
  }
}
