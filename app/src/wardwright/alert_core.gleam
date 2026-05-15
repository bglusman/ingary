pub type OnFull {
  DeadLetter
  Drop
  FailClosed
}

pub type SinkBehavior {
  Fast
  Slow
  FailThenRecover
}

pub type Config {
  Config(
    capacity: Int,
    on_full: OnFull,
    sink_behavior: SinkBehavior,
    retry_limit: Int,
  )
}

pub type Alert {
  Alert(idempotency_key: String, rule_id: String, session_id: String)
}

pub type DeliveryStatus {
  Enqueued
  Duplicate(existing_status: DeliveryStatus)
  DeadLettered
  Dropped
  Blocked
  Delivered
  Retrying
  Failed
}

pub type EnqueueDecision {
  EnqueueDecision(
    key: String,
    status: DeliveryStatus,
    queue_depth: Int,
    queue_capacity: Int,
  )
}

pub fn decide_enqueue(
  config: Config,
  queue_depth: Int,
  already_seen: Bool,
  alert: Alert,
  existing_status: DeliveryStatus,
) -> EnqueueDecision {
  case already_seen {
    True ->
      EnqueueDecision(
        key: alert.idempotency_key,
        status: Duplicate(existing_status),
        queue_depth: queue_depth,
        queue_capacity: config.capacity,
      )

    False if queue_depth >= config.capacity ->
      EnqueueDecision(
        key: alert.idempotency_key,
        status: full_status(config.on_full),
        queue_depth: queue_depth,
        queue_capacity: config.capacity,
      )

    False ->
      EnqueueDecision(
        key: alert.idempotency_key,
        status: Enqueued,
        queue_depth: queue_depth + 1,
        queue_capacity: config.capacity,
      )
  }
}

pub fn classify_attempt(
  behavior: SinkBehavior,
  attempt: Int,
  retry_limit: Int,
) -> DeliveryStatus {
  case behavior, attempt <= retry_limit {
    FailThenRecover, True if attempt == 1 -> Retrying
    FailThenRecover, False if attempt == 1 -> Failed
    _, _ -> Delivered
  }
}

pub fn terminal(status: DeliveryStatus) -> Bool {
  case status {
    Enqueued | Retrying -> False
    Duplicate(_) | DeadLettered | Dropped | Blocked | Delivered | Failed -> True
  }
}

fn full_status(on_full: OnFull) -> DeliveryStatus {
  case on_full {
    DeadLetter -> DeadLettered
    Drop -> Dropped
    FailClosed -> Blocked
  }
}
