pub type StreamAction {
  Annotate
  Block
  DropChunk
  Pass
  Retry
  RewriteChunk
  RewriteWindow
}

pub fn action_for(action: String, match_scope: String) -> StreamAction {
  case action, match_scope {
    "rewrite", "stream_window" -> RewriteWindow
    "rewrite", _ -> RewriteChunk
    "rewrite_chunk", "stream_window" -> RewriteWindow
    "rewrite_chunk", _ -> RewriteChunk
    "drop_chunk", _ -> DropChunk
    "block", _ -> Block
    "block_final", _ -> Block
    "retry", _ -> Retry
    "retry_with_reminder", _ -> Retry
    "pass", _ -> Pass
    _, _ -> Annotate
  }
}

pub fn action_tag(action: String, match_scope: String) -> String {
  case action_for(action, match_scope) {
    RewriteWindow -> "rewrite_window"
    RewriteChunk -> "rewrite_chunk"
    DropChunk -> "drop_chunk"
    Block -> "block"
    Retry -> "retry"
    Pass -> "pass"
    Annotate -> "annotate"
  }
}

pub fn terminal_status(action: String) -> String {
  case action_for(action, "chunk") {
    Block -> "stream_policy_blocked"
    Retry -> "stream_policy_retry_required"
    _ -> "completed"
  }
}

pub fn latency_exceeded(observed_ms: Int, max_hold_ms: Int) -> Bool {
  observed_ms > max_hold_ms
}

pub fn release_budget(stream_window_bytes: Int, horizon_bytes: Int) -> Int {
  let budget = stream_window_bytes - horizon_bytes
  case budget > 0 {
    True -> budget
    False -> 0
  }
}

pub fn rewritten_bytes(generated_bytes: Int, unchanged: Bool) -> Int {
  case unchanged {
    True -> 0
    False -> generated_bytes
  }
}
