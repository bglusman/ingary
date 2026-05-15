pub type RuleDecision {
  NotTriggered(
    scope: String,
    count: Int,
    threshold: Int,
    recent_limit: Int,
    working_set_size: Int,
  )
  Triggered(
    scope: String,
    count: Int,
    threshold: Int,
    recent_limit: Int,
    working_set_size: Int,
  )
}

pub fn count_matches(
  matches: List(Bool),
  threshold threshold: Int,
  recent_limit recent_limit: Int,
  working_set_size working_set_size: Int,
  scope scope: String,
) -> RuleDecision {
  let bounded_limit = clamp_positive(recent_limit)
  let bounded_threshold = clamp_positive(threshold)
  let count = count_true_recent(matches, bounded_limit, 0)

  case count >= bounded_threshold {
    True ->
      Triggered(
        scope: scope,
        count: count,
        threshold: bounded_threshold,
        recent_limit: bounded_limit,
        working_set_size: working_set_size,
      )

    False ->
      NotTriggered(
        scope: scope,
        count: count,
        threshold: bounded_threshold,
        recent_limit: bounded_limit,
        working_set_size: working_set_size,
      )
  }
}

fn clamp_positive(value: Int) -> Int {
  case value > 0 {
    True -> value
    False -> 1
  }
}

fn count_true_recent(matches: List(Bool), remaining: Int, count: Int) -> Int {
  case matches, remaining {
    _, 0 -> count
    [], _ -> count
    [True, ..rest], _ -> count_true_recent(rest, remaining - 1, count + 1)
    [False, ..rest], _ -> count_true_recent(rest, remaining - 1, count)
  }
}
