from __future__ import annotations

import json
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from bakeoff_support import chat_request, install_test_config, request_json


FIXTURE_PATH = Path(__file__).parent / "fixtures" / "bakeoff_alert_backpressure" / "canned_alert_runs.json"


AlertOutcome = Literal[
    "queued",
    "duplicate_suppressed",
    "dead_lettered",
    "dropped",
    "failed_closed",
    "not_alerting",
]


@dataclass(frozen=True)
class AlertDecision:
    decision_id: str
    triggers_alert: bool
    idempotency_key: str


@dataclass(frozen=True)
class AlertResult:
    decision_id: str
    outcome: AlertOutcome
    idempotency_key: str


def alert_queue_oracle(
    decisions: list[AlertDecision],
    *,
    capacity: int,
    on_full: Literal["drop", "dead_letter", "fail_closed"],
) -> list[AlertResult]:
    queue: deque[str] = deque()
    seen_keys: set[str] = set()
    results: list[AlertResult] = []
    for decision in decisions:
        if not decision.triggers_alert:
            results.append(AlertResult(decision.decision_id, "not_alerting", decision.idempotency_key))
            continue
        if decision.idempotency_key in seen_keys:
            results.append(AlertResult(decision.decision_id, "duplicate_suppressed", decision.idempotency_key))
            continue
        seen_keys.add(decision.idempotency_key)
        if len(queue) < capacity:
            queue.append(decision.idempotency_key)
            results.append(AlertResult(decision.decision_id, "queued", decision.idempotency_key))
        elif on_full == "drop":
            results.append(AlertResult(decision.decision_id, "dropped", decision.idempotency_key))
        elif on_full == "dead_letter":
            results.append(AlertResult(decision.decision_id, "dead_lettered", decision.idempotency_key))
        else:
            results.append(AlertResult(decision.decision_id, "failed_closed", decision.idempotency_key))
    return results


def load_canned_alert_runs() -> list[dict[str, object]]:
    return json.loads(FIXTURE_PATH.read_text())


def alert_decision_from_fixture(item: dict[str, object]) -> AlertDecision:
    return AlertDecision(
        decision_id=str(item["decision_id"]),
        triggers_alert=bool(item["triggers_alert"]),
        idempotency_key=str(item["idempotency_key"]),
    )


decision_strategy = st.lists(
    st.builds(
        AlertDecision,
        decision_id=st.text(
            alphabet=st.characters(whitelist_categories=("Ll", "Lu", "Nd")),
            min_size=1,
            max_size=12,
        ),
        triggers_alert=st.booleans(),
        idempotency_key=st.sampled_from(["same-alert", "alert-a", "alert-b", "alert-c", "alert-d"]),
    ),
    min_size=0,
    max_size=40,
)


@given(
    decision_strategy,
    st.integers(min_value=0, max_value=10),
    st.sampled_from(["drop", "dead_letter", "fail_closed"]),
)
@settings(max_examples=100)
def test_alert_oracle_never_exceeds_queue_capacity(
    decisions: list[AlertDecision],
    capacity: int,
    on_full: Literal["drop", "dead_letter", "fail_closed"],
) -> None:
    results = alert_queue_oracle(decisions, capacity=capacity, on_full=on_full)

    queued = [result for result in results if result.outcome == "queued"]
    assert len(queued) <= capacity
    assert len(results) == len(decisions)
    assert all(
        result.outcome == "not_alerting"
        for decision, result in zip(decisions, results)
        if not decision.triggers_alert
    )


@given(decision_strategy, st.integers(min_value=0, max_value=10))
@settings(max_examples=100)
def test_alert_oracle_idempotency_keys_are_not_enqueued_twice(
    decisions: list[AlertDecision],
    capacity: int,
) -> None:
    results = alert_queue_oracle(decisions, capacity=capacity, on_full="dead_letter")

    queued_keys = [result.idempotency_key for result in results if result.outcome == "queued"]
    assert len(queued_keys) == len(set(queued_keys))
    seen_trigger_keys: set[str] = set()
    for decision, result in zip(decisions, results):
        if result.outcome == "duplicate_suppressed":
            assert decision.idempotency_key in seen_trigger_keys
        if decision.triggers_alert:
            seen_trigger_keys.add(decision.idempotency_key)


@pytest.mark.parametrize("scenario", load_canned_alert_runs(), ids=lambda item: str(item["name"]))
def test_alert_oracle_matches_canned_backpressure_scenarios(scenario: dict[str, object]) -> None:
    decisions = [
        alert_decision_from_fixture(item)
        for item in scenario["decisions"]  # type: ignore[index]
    ]
    results = alert_queue_oracle(
        decisions,
        capacity=int(scenario["queue_capacity"]),
        on_full=scenario["on_full"],  # type: ignore[arg-type]
    )

    assert [result.outcome for result in results] == scenario["expected_outcomes"]


def alert_config(
    *,
    queue_capacity: int = 4,
    on_full: Literal["drop", "dead_letter", "fail_closed"] = "dead_letter",
    sink_schedule: list[str] | None = None,
) -> dict[str, object]:
    return {
        "synthetic_model": "bakeoff-alerts",
        "version": "bakeoff-alerts-v1",
        "targets": [{"model": "mock/alerts", "context_window": 4096}],
        "alert_sinks": [
            {
                "id": "operator-webhook",
                "kind": "test_sink",
                "delivery_schedule": sink_schedule or ["success"],
                "idempotency": "alert_id",
            }
        ],
        "alert_delivery": {
            "mode": "async",
            "request_latency_budget_ms": 50,
            "queue_capacity": queue_capacity,
            "on_full": on_full,
            "retry_attempts": 2,
            "dead_letter_enabled": True,
        },
        "governance": [
            {
                "id": "operator-alert",
                "kind": "request_guard",
                "action": "alert_async",
                "contains": "needs operator",
                "severity": "warning",
                "sink_id": "operator-webhook",
                "message": "Request needs operator review.",
            }
        ],
    }


def simulate_alerting_request(base_url: str, *, content: str, timeout: float) -> dict[str, object]:
    resp = request_json(
        base_url,
        "POST",
        "/v1/synthetic/simulate",
        {"request": chat_request("wardwright/bakeoff-alerts", content)},
        timeout=timeout,
    )
    assert resp.status == 200, f"simulate failed status={resp.status} body={resp.body!r}"
    return resp.body["receipt"]


@pytest.mark.backend
def test_alert_backend_fast_sink_records_single_delivery(base_url: str, backend_timeout: float) -> None:
    install_test_config(base_url, alert_config(), timeout=backend_timeout)

    receipt = simulate_alerting_request(
        base_url,
        content="This needs operator review before continuing.",
        timeout=backend_timeout,
    )

    final = receipt.get("final", {})
    delivery = final.get("alert_delivery", {})
    assert final.get("alert_count") == 1
    assert delivery.get("sink_id") == "operator-webhook"
    assert delivery.get("outcome") in {"queued", "delivered"}
    assert delivery.get("idempotency_key")
    assert delivery.get("request_path_blocked") is False


@pytest.mark.backend
def test_alert_backend_full_queue_dead_letters_without_silent_loss(
    base_url: str,
    backend_timeout: float,
) -> None:
    install_test_config(
        base_url,
        alert_config(queue_capacity=1, on_full="dead_letter", sink_schedule=["timeout"]),
        timeout=backend_timeout,
    )

    first = simulate_alerting_request(
        base_url,
        content="first request needs operator review",
        timeout=backend_timeout,
    )
    second = simulate_alerting_request(
        base_url,
        content="second request needs operator review",
        timeout=backend_timeout,
    )

    first_delivery = first.get("final", {}).get("alert_delivery", {})
    second_delivery = second.get("final", {}).get("alert_delivery", {})
    assert first_delivery.get("outcome") in {"queued", "delivered"}
    assert second_delivery.get("outcome") == "dead_lettered"
    assert second_delivery.get("reason") == "queue_full"
    assert second.get("final", {}).get("alert_count") == 1


@pytest.mark.backend
def test_alert_backend_fail_closed_queue_full_blocks_request(base_url: str, backend_timeout: float) -> None:
    install_test_config(
        base_url,
        alert_config(queue_capacity=0, on_full="fail_closed", sink_schedule=["timeout"]),
        timeout=backend_timeout,
    )

    resp = request_json(
        base_url,
        "POST",
        "/v1/chat/completions",
        chat_request("wardwright/bakeoff-alerts", "This needs operator review before release."),
        timeout=backend_timeout,
    )

    assert resp.status in (429, 503), f"fail-closed full alert queue must block request, got {resp.status}"
    body = resp.body if isinstance(resp.body, dict) else {}
    delivery = body.get("receipt", {}).get("final", {}).get("alert_delivery", {})
    assert delivery.get("outcome") == "failed_closed"
    assert delivery.get("reason") == "queue_full"
