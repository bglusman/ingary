pub type SelectorKind {
  Alloy
  Cascade
  Dispatcher
}

pub type Target {
  Target(model: String, context_window: Int, weight: Int)
}

pub type RouteSkip {
  ContextTooSmall(
    target: String,
    context_window: Int,
    estimated_prompt_tokens: Int,
  )
}

pub type RouteSelection {
  RouteSelection(
    selected_model: String,
    selected_context_window: Int,
    selected_models: List(String),
    fallback_models: List(String),
    skipped: List(RouteSkip),
    route_blocked: Bool,
    reason: String,
  )
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

pub fn select_dispatcher(
  models: List(Target),
  all_targets: List(Target),
  estimated_prompt_tokens: Int,
) -> RouteSelection {
  let #(eligible, skipped) = split_by_context(models, estimated_prompt_tokens)
  let selected = first_or_largest(eligible, all_targets)
  route_selection(
    selected,
    eligible,
    skipped,
    dispatcher_reason(length(skipped)),
  )
}

pub fn select_cascade(
  models: List(Target),
  all_targets: List(Target),
  estimated_prompt_tokens: Int,
) -> RouteSelection {
  let #(eligible, skipped) = split_by_context(models, estimated_prompt_tokens)
  let selected = first_or_largest(eligible, all_targets)
  route_selection(selected, eligible, skipped, cascade_reason(length(skipped)))
}

fn route_selection(
  selected: Result(Target, Nil),
  eligible: List(Target),
  skipped: List(RouteSkip),
  reason: String,
) -> RouteSelection {
  let selected_names = selected_models(selected, eligible)
  RouteSelection(
    selected_model: selected_model(selected),
    selected_context_window: selected_context_window(selected),
    selected_models: selected_names,
    fallback_models: drop(selected_names, 1),
    skipped: skipped,
    route_blocked: result_is_error(selected),
    reason: reason,
  )
}

fn split_by_context(
  models: List(Target),
  estimated_prompt_tokens: Int,
) -> #(List(Target), List(RouteSkip)) {
  let #(eligible, skipped) =
    split_by_context_loop(models, #([], []), estimated_prompt_tokens)

  #(reverse(eligible), reverse(skipped))
}

fn split_by_context_loop(
  models: List(Target),
  acc: #(List(Target), List(RouteSkip)),
  estimated_prompt_tokens: Int,
) -> #(List(Target), List(RouteSkip)) {
  case models {
    [] -> acc
    [model, ..rest] -> {
      let #(eligible, skipped) = acc
      case model.context_window >= estimated_prompt_tokens {
        True ->
          split_by_context_loop(
            rest,
            #([model, ..eligible], skipped),
            estimated_prompt_tokens,
          )
        False ->
          split_by_context_loop(
            rest,
            #(eligible, [
              ContextTooSmall(
                target: model.model,
                context_window: model.context_window,
                estimated_prompt_tokens: estimated_prompt_tokens,
              ),
              ..skipped
            ]),
            estimated_prompt_tokens,
          )
      }
    }
  }
}

fn first_or_largest(
  eligible: List(Target),
  all_targets: List(Target),
) -> Result(Target, Nil) {
  case eligible {
    [target, ..] -> Ok(target)
    [] -> largest_known_model(all_targets)
  }
}

fn largest_known_model(models: List(Target)) -> Result(Target, Nil) {
  case models {
    [] -> Error(Nil)
    [first, ..rest] -> Ok(last(first, rest))
  }
}

fn last(current: a, rest: List(a)) -> a {
  case rest {
    [] -> current
    [next, ..remaining] -> last(next, remaining)
  }
}

fn selected_models(
  selected: Result(Target, Nil),
  eligible: List(Target),
) -> List(String) {
  case selected, eligible {
    Ok(_target), [] -> [selected_model(selected)]
    _, _ -> target_names(eligible)
  }
}

fn selected_model(selected: Result(Target, Nil)) -> String {
  case selected {
    Ok(target) -> target.model
    Error(Nil) -> "unconfigured/no-target"
  }
}

fn selected_context_window(selected: Result(Target, Nil)) -> Int {
  case selected {
    Ok(target) -> target.context_window
    Error(Nil) -> 0
  }
}

fn result_is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}

fn target_names(targets: List(Target)) -> List(String) {
  case targets {
    [] -> []
    [target, ..rest] -> [target.model, ..target_names(rest)]
  }
}

fn drop(items: List(a), count: Int) -> List(a) {
  case items, count <= 0 {
    _, True -> items
    [], False -> []
    [_first, ..rest], False -> drop(rest, count - 1)
  }
}

fn length(items: List(a)) -> Int {
  length_loop(items, 0)
}

fn length_loop(items: List(a), count: Int) -> Int {
  case items {
    [] -> count
    [_first, ..rest] -> length_loop(rest, count + 1)
  }
}

fn reverse(items: List(a)) -> List(a) {
  reverse_loop(items, [])
}

fn reverse_loop(items: List(a), acc: List(a)) -> List(a) {
  case items {
    [] -> acc
    [first, ..rest] -> reverse_loop(rest, [first, ..acc])
  }
}
