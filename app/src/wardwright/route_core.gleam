pub type SelectorKind {
  Alloy
  Cascade
  Dispatcher
}

pub fn normalize_alloy_strategy(strategy: String) -> String {
  case strategy {
    "deterministic_all" | "weighted" | "round_robin" -> strategy
    "all" -> "deterministic_all"
    _ -> "weighted"
  }
}

pub fn dispatcher_reason(skipped_count: Int) -> String {
  case skipped_count {
    0 -> "estimated prompt fits selected context window"
    _ -> "estimated prompt exceeded smaller configured context windows"
  }
}

pub fn cascade_reason(skipped_count: Int) -> String {
  case skipped_count {
    0 -> "selected first configured cascade target"
    _ -> "cascade skipped targets whose context windows were too small"
  }
}

pub fn alloy_reason(partial_context: Bool, skipped_count: Int) -> String {
  case partial_context, skipped_count {
    True, 0 ->
      "partial alloy selected all constituents whose context windows fit"
    True, _ ->
      "partial alloy dropped smaller constituents whose context windows were too small"
    False, 0 ->
      "alloy constituents share a compatible context window for this prompt"
    False, _ -> "alloy prompt exceeded the compatible minimum context window"
  }
}

pub fn forced_model_reason(available: Bool, fits_prompt: Bool) -> String {
  case available, fits_prompt {
    False, _ -> "policy forced model was not in the allowed route set"
    True, False -> "policy forced model was too small for estimated prompt"
    True, True -> "policy forced selected model"
  }
}

pub fn forced_fallback_reason(forced_reason: String) -> String {
  forced_reason <> "; explicit policy fallback allowed"
}

pub fn default_root(
  configured_root: String,
  first_dispatcher: String,
  first_cascade: String,
  first_alloy: String,
) -> String {
  case configured_root, first_dispatcher, first_cascade, first_alloy {
    root, _, _, _ if root != "" -> root
    _, dispatcher, _, _ if dispatcher != "" -> dispatcher
    _, _, cascade, _ if cascade != "" -> cascade
    _, _, _, alloy if alloy != "" -> alloy
    _, _, _, _ -> "__targets_dispatcher__"
  }
}

pub fn validate_strategy(raw: String) -> Bool {
  case raw {
    "weighted" | "round_robin" | "deterministic_all" | "all" -> True
    _ -> False
  }
}
