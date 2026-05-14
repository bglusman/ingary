from __future__ import annotations

import concurrent.futures
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from bakeoff_support import chat_request, install_test_config, request_json, response_receipt


FIXTURE_PATH = Path(__file__).parent / "fixtures" / "bakeoff_history_governor" / "canned_histories.json"


@dataclass(frozen=True)
class HistoryEvent:
    sequence: int
    created_at_unix_ms: int
    session_id: str
    kind: str
    key: str


def retained_events(events: list[HistoryEvent], max_entries: int) -> list[HistoryEvent]:
    ordered = sorted(events, key=lambda event: (event.created_at_unix_ms, event.sequence))
    return ordered[-max_entries:] if max_entries else []


def load_canned_histories() -> list[dict[str, Any]]:
    return json.loads(FIXTURE_PATH.read_text())


def history_event_from_fixture(item: dict[str, Any]) -> HistoryEvent:
    return HistoryEvent(
        sequence=int(item["sequence"]),
        created_at_unix_ms=int(item["created_at_unix_ms"]),
        session_id=str(item["session_id"]),
        kind=str(item["kind"]),
        key=str(item["key"]),
    )


def history_count(
    events: list[HistoryEvent],
    *,
    max_entries: int,
    session_id: str,
    kind: str,
    key: str,
) -> int:
    return sum(
        1
        for event in retained_events(events, max_entries)
        if event.session_id == session_id and event.kind == kind and event.key == key
    )


events_strategy = st.lists(
    st.builds(
        HistoryEvent,
        sequence=st.integers(min_value=1, max_value=200),
        created_at_unix_ms=st.integers(min_value=0, max_value=1000),
        session_id=st.sampled_from(["session-a", "session-b", "session-c"]),
        kind=st.sampled_from(["tool_call", "response_text", "receipt_event"]),
        key=st.sampled_from(["shell:ls", "shell:rm", "regex:secret", "note"]),
    ),
    min_size=0,
    max_size=80,
    unique_by=lambda event: event.sequence,
)


@given(events_strategy, st.integers(min_value=1, max_value=20))
@settings(max_examples=100)
def test_history_oracle_is_session_scoped(events: list[HistoryEvent], max_entries: int) -> None:
    count_a = history_count(
        events,
        max_entries=max_entries,
        session_id="session-a",
        kind="tool_call",
        key="shell:ls",
    )
    count_b = history_count(
        events,
        max_entries=max_entries,
        session_id="session-b",
        kind="tool_call",
        key="shell:ls",
    )

    manual_a = [
        event
        for event in retained_events(events, max_entries)
        if event.session_id == "session-a" and event.kind == "tool_call" and event.key == "shell:ls"
    ]
    manual_b = [
        event
        for event in retained_events(events, max_entries)
        if event.session_id == "session-b" and event.kind == "tool_call" and event.key == "shell:ls"
    ]
    assert count_a == len(manual_a)
    assert count_b == len(manual_b)


@given(events_strategy, st.integers(min_value=1, max_value=20))
@settings(max_examples=100)
def test_history_oracle_retention_is_timestamp_then_sequence(events: list[HistoryEvent], max_entries: int) -> None:
    retained = retained_events(events, max_entries)

    assert len(retained) <= max_entries
    if len(events) > max_entries:
        retained_keys = {(event.created_at_unix_ms, event.sequence) for event in retained}
        evicted = sorted(events, key=lambda event: (event.created_at_unix_ms, event.sequence))[:-max_entries]
        assert not retained_keys.intersection(
            (event.created_at_unix_ms, event.sequence) for event in evicted
        )


@pytest.mark.parametrize("scenario", load_canned_histories(), ids=lambda item: item["name"])
def test_history_oracle_matches_canned_scope_and_eviction_scenarios(scenario: dict[str, Any]) -> None:
    events = [history_event_from_fixture(item) for item in scenario["events"]]
    retained = retained_events(events, int(scenario["max_entries"]))
    count = history_count(
        events,
        max_entries=int(scenario["max_entries"]),
        session_id=str(scenario["session_id"]),
        kind=str(scenario["kind"]),
        key=str(scenario["key"]),
    )

    assert count == scenario["expected_count"]
    assert (count >= int(scenario["threshold"])) is scenario["expected_trigger"]
    if "expected_retained_sequences" in scenario:
        assert [event.sequence for event in retained] == scenario["expected_retained_sequences"]


def history_config(*, max_entries: int = 8, recent_limit: int = 8, threshold: int = 2) -> dict[str, Any]:
    return {
        "synthetic_model": "bakeoff-history",
        "version": "bakeoff-history-v1",
        "targets": [{"model": "mock/history", "context_window": 4096}],
        "policy_cache": {"max_entries": max_entries, "recent_limit": recent_limit},
        "governance": [
            {
                "id": "repeat-shell-ls",
                "kind": "history_threshold",
                "action": "escalate",
                "cache_kind": "tool_call",
                "cache_key": "shell:ls",
                "cache_scope": "session_id",
                "threshold": threshold,
                "severity": "warning",
            }
        ],
    }


def request_text_history_config(marker: str, *, threshold: int = 2) -> dict[str, Any]:
    return {
        "synthetic_model": "bakeoff-history-requests",
        "version": "bakeoff-history-requests-v1",
        "targets": [{"model": "mock/history-requests", "context_window": 4096}],
        "policy_cache": {"max_entries": 16, "recent_limit": 16},
        "governance": [
            {
                "id": "repeated-request-marker",
                "kind": "history_threshold",
                "action": "escalate",
                "source_kind": "request_text",
                "match": {
                    "kind": "literal",
                    "field": "messages.content",
                    "pattern": marker,
                },
                "cache_scope": "session_id",
                "threshold": threshold,
                "severity": "warning",
            }
        ],
    }


def add_cache_event(
    base_url: str,
    *,
    session_id: str,
    key: str = "shell:ls",
    kind: str = "tool_call",
    created_at_unix_ms: int = 0,
    timeout: float = 10,
) -> dict[str, Any]:
    resp = request_json(
        base_url,
        "POST",
        "/v1/policy-cache/events",
        {
            "kind": kind,
            "key": key,
            "scope": {"session_id": session_id},
            "value": {"status": "ok"},
            "created_at_unix_ms": created_at_unix_ms,
        },
        timeout=timeout,
    )
    assert resp.status == 201, f"cache insert failed status={resp.status} body={resp.body!r}"
    return resp.body["event"]


def simulate_history_policy(base_url: str, *, timeout: float) -> dict[str, Any]:
    resp = request_json(
        base_url,
        "POST",
        "/v1/synthetic/simulate",
        {"request": chat_request("ingary/bakeoff-history", "Check recent tool behavior.")},
        timeout=timeout,
    )
    assert resp.status == 200, f"simulate failed status={resp.status} body={resp.body!r}"
    return resp.body["receipt"]


@pytest.mark.backend
def test_history_backend_manual_cache_events_count_only_current_session_scope(
    base_url: str,
    backend_timeout: float,
) -> None:
    install_test_config(base_url, history_config(), timeout=backend_timeout)
    add_cache_event(base_url, session_id="other-session", timeout=backend_timeout)
    add_cache_event(base_url, session_id="bakeoff-session", key="shell:rm", timeout=backend_timeout)
    add_cache_event(base_url, session_id="bakeoff-session", timeout=backend_timeout)

    miss_receipt = simulate_history_policy(base_url, timeout=backend_timeout)
    assert miss_receipt["final"]["alert_count"] == 0, (
        "one matching in-scope event plus matching out-of-scope and irrelevant "
        f"in-scope events must not trigger: {miss_receipt!r}"
    )

    add_cache_event(base_url, session_id="bakeoff-session", timeout=backend_timeout)
    hit_receipt = simulate_history_policy(base_url, timeout=backend_timeout)
    actions = hit_receipt.get("decision", {}).get("policy_actions", [])
    assert hit_receipt["final"]["alert_count"] == 1
    assert actions and actions[0].get("history_count") == 2
    assert actions[0].get("threshold") == 2
    assert actions[0].get("scope", {}).get("session_id") == "bakeoff-session"


@pytest.mark.backend
def test_history_backend_manual_cache_eviction_is_deterministic_by_timestamp_then_sequence(
    base_url: str,
    backend_timeout: float,
) -> None:
    install_test_config(base_url, history_config(max_entries=3, recent_limit=10, threshold=99), timeout=backend_timeout)
    inserted = [
        add_cache_event(base_url, session_id="bakeoff-session", created_at_unix_ms=20, timeout=backend_timeout),
        add_cache_event(base_url, session_id="bakeoff-session", created_at_unix_ms=10, timeout=backend_timeout),
        add_cache_event(base_url, session_id="bakeoff-session", created_at_unix_ms=20, timeout=backend_timeout),
        add_cache_event(base_url, session_id="bakeoff-session", created_at_unix_ms=5, timeout=backend_timeout),
    ]
    expected_sequences = {
        event["sequence"]
        for event in sorted(inserted, key=lambda event: (event["created_at_unix_ms"], event["sequence"]))[-3:]
    }

    recent = request_json(
        base_url,
        "GET",
        "/v1/policy-cache/recent?kind=tool_call&key=shell%3Als&session_id=bakeoff-session&limit=10",
        timeout=backend_timeout,
    )

    assert recent.status == 200, f"recent query failed status={recent.status} body={recent.body!r}"
    observed_sequences = {event["sequence"] for event in recent.body.get("data", [])}
    assert observed_sequences == expected_sequences


@pytest.mark.backend
def test_history_backend_manual_cache_concurrent_writes_in_one_session_are_all_visible(
    base_url: str,
    backend_timeout: float,
) -> None:
    install_test_config(base_url, history_config(max_entries=32, recent_limit=32, threshold=8), timeout=backend_timeout)

    def insert(index: int) -> int:
        event = add_cache_event(
            base_url,
            session_id="bakeoff-session",
            created_at_unix_ms=index,
            timeout=backend_timeout,
        )
        return int(event["sequence"])

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        sequences = list(executor.map(insert, range(8)))

    assert len(sequences) == 8
    assert len(set(sequences)) == 8
    receipt = simulate_history_policy(base_url, timeout=backend_timeout)
    actions = receipt.get("decision", {}).get("policy_actions", [])
    assert receipt["final"]["alert_count"] == 1
    assert actions and actions[0].get("history_count") == 8


@pytest.mark.backend
def test_history_backend_normal_requests_feed_session_history_policy(
    base_url: str,
    backend_timeout: float,
) -> None:
    marker = "NEEDS_HISTORY_GOVERNOR_42"
    install_test_config(base_url, request_text_history_config(marker), timeout=backend_timeout)

    first = request_json(
        base_url,
        "POST",
        "/v1/chat/completions",
        chat_request(
            "ingary/bakeoff-history-requests",
            f"First normal request with {marker}.",
        ),
        timeout=backend_timeout,
    )
    assert first.status == 200, f"first chat failed status={first.status} body={first.body!r}"
    first_receipt = response_receipt(base_url, first, timeout=backend_timeout)
    assert first_receipt["final"]["alert_count"] == 0

    second = request_json(
        base_url,
        "POST",
        "/v1/chat/completions",
        chat_request(
            "ingary/bakeoff-history-requests",
            f"Second normal request with {marker}.",
        ),
        timeout=backend_timeout,
    )
    assert second.status == 200, f"second chat failed status={second.status} body={second.body!r}"
    receipt = response_receipt(base_url, second, timeout=backend_timeout)
    actions = receipt.get("decision", {}).get("policy_actions", [])
    assert receipt["final"]["alert_count"] == 1
    assert actions and actions[0].get("rule_id") == "repeated-request-marker"
    assert actions[0].get("history_count") == 2
    assert actions[0].get("scope", {}).get("session_id") == "bakeoff-session"
