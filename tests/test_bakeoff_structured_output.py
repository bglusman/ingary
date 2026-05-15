from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import jsonschema
import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from bakeoff_support import chat_request, install_test_config, request_json, response_receipt


FIXTURE_PATH = Path(__file__).parent / "fixtures" / "bakeoff_structured_output" / "canned_sequences.json"


ANSWER_SCHEMA = {
    "type": "object",
    "required": ["answer", "confidence"],
    "properties": {
        "answer": {"type": "string", "minLength": 1},
        "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        "citations": {"type": "array", "items": {"type": "string"}},
    },
    "additionalProperties": False,
}


@dataclass(frozen=True)
class GuardLoopResult:
    final_status: str
    guard_events: list[dict[str, Any]]
    selected_schema: str | None
    parsed_output: Any | None


def _parse_json(text: str) -> tuple[Any | None, str | None]:
    try:
        return json.loads(text), None
    except json.JSONDecodeError as exc:
        return None, f"json_syntax:{exc.msg}"


def structured_guard_loop_oracle(outputs: list[str], *, max_attempts: int = 3) -> GuardLoopResult:
    validator = jsonschema.Draft202012Validator(ANSWER_SCHEMA)
    guard_events: list[dict[str, Any]] = []
    for attempt_index, output in enumerate(outputs[:max_attempts]):
        parsed, parse_error = _parse_json(output)
        if parse_error:
            guard_events.append(
                {
                    "type": "structured_output.guard",
                    "attempt_index": attempt_index,
                    "rule_id": "answer-json",
                    "guard_type": "json_syntax",
                    "action": "retry_with_validation_feedback",
                }
            )
            continue
        errors = sorted(validator.iter_errors(parsed), key=lambda err: list(err.path))
        if errors:
            guard_events.append(
                {
                    "type": "structured_output.guard",
                    "attempt_index": attempt_index,
                    "rule_id": "answer-json",
                    "guard_type": "schema_validation",
                    "action": "retry_with_validation_feedback",
                }
            )
            continue
        if parsed["confidence"] < 0.7:
            guard_events.append(
                {
                    "type": "structured_output.guard",
                    "attempt_index": attempt_index,
                    "rule_id": "minimum-confidence",
                    "guard_type": "semantic_validation",
                    "action": "retry_with_validation_feedback",
                }
            )
            continue
        return GuardLoopResult(
            final_status="completed_after_guard" if guard_events else "completed",
            guard_events=guard_events,
            selected_schema="answer_v1",
            parsed_output=parsed,
        )
    return GuardLoopResult(
        final_status="exhausted_guard_budget",
        guard_events=guard_events,
        selected_schema=None,
        parsed_output=None,
    )


def structured_output_config(outputs: list[str], *, max_attempts: int = 3) -> dict[str, Any]:
    return {
        "synthetic_model": "bakeoff-structured-output",
        "version": "bakeoff-structured-output-v1",
        "targets": [{"model": "mock/structured-output", "context_window": 4096}],
        "structured_output": {
            "schemas": [{"id": "answer_v1", "schema": ANSWER_SCHEMA}],
            "semantic_rules": [
                {
                    "id": "minimum-confidence",
                    "kind": "json_path_number",
                    "path": "/confidence",
                    "gte": 0.7,
                }
            ],
            "guard_loop": {
                "max_attempts": max_attempts,
                "max_failures_per_rule": 2,
                "on_violation": "retry_with_validation_feedback",
                "on_exhausted": "block",
            },
        },
        "test_provider": {
            "kind": "canned_sequence",
            "outputs": outputs,
        },
    }


valid_answer = st.builds(
    lambda answer, confidence, citations: {
        "answer": answer,
        "confidence": confidence,
        "citations": citations,
    },
    answer=st.text(min_size=1, max_size=80),
    confidence=st.floats(min_value=0.7, max_value=1, allow_nan=False, allow_infinity=False),
    citations=st.lists(st.text(min_size=1, max_size=40), max_size=3),
)


invalid_then_valid_outputs = st.tuples(
    st.one_of(
        st.just("{not json"),
        st.just(json.dumps({"answer": "too uncertain", "confidence": 0.1})),
        st.just(json.dumps({"answer": "missing confidence"})),
    ),
    valid_answer,
).map(lambda pair: [pair[0], json.dumps(pair[1])])


def load_canned_sequences() -> list[dict[str, Any]]:
    return json.loads(FIXTURE_PATH.read_text())


@given(valid_answer)
@settings(max_examples=50)
def test_structured_oracle_accepts_valid_outputs_without_guard(valid_output: dict[str, Any]) -> None:
    result = structured_guard_loop_oracle([json.dumps(valid_output)])

    assert result.final_status == "completed"
    assert result.guard_events == []
    assert result.selected_schema == "answer_v1"
    assert result.parsed_output == valid_output


@given(invalid_then_valid_outputs)
@settings(max_examples=50)
def test_structured_oracle_records_guard_count_before_success(outputs: list[str]) -> None:
    result = structured_guard_loop_oracle(outputs)

    assert result.final_status == "completed_after_guard"
    assert len(result.guard_events) == 1
    assert result.guard_events[0]["attempt_index"] == 0
    assert result.guard_events[0]["action"] == "retry_with_validation_feedback"
    assert result.parsed_output is not None


@given(st.lists(st.just("{not json"), min_size=3, max_size=3))
def test_structured_oracle_exhausts_attempt_budget(outputs: list[str]) -> None:
    result = structured_guard_loop_oracle(outputs, max_attempts=3)

    assert result.final_status == "exhausted_guard_budget"
    assert len(result.guard_events) == 3
    assert {event["guard_type"] for event in result.guard_events} == {"json_syntax"}


@pytest.mark.parametrize("scenario", load_canned_sequences(), ids=lambda item: item["name"])
def test_structured_oracle_matches_canned_regeneration_paths(scenario: dict[str, Any]) -> None:
    expected = scenario["expected"]
    result = structured_guard_loop_oracle(
        scenario["outputs"],
        max_attempts=expected["attempt_count"],
    )

    assert result.final_status == expected["final_status"], scenario["description"]
    assert len(result.guard_events) == len(expected["guard_types"])
    assert [event["guard_type"] for event in result.guard_events] == expected["guard_types"]
    assert [event["rule_id"] for event in result.guard_events] == expected["guard_rule_ids"]
    if result.final_status != "exhausted_guard_budget":
        assert result.parsed_output is not None


@pytest.mark.backend
def test_structured_backend_repairs_invalid_output_then_succeeds(base_url: str, backend_timeout: float) -> None:
    outputs = [
        json.dumps({"answer": "too uncertain", "confidence": 0.2}),
        json.dumps({"answer": "Use the current API.", "confidence": 0.93}),
    ]
    install_test_config(base_url, structured_output_config(outputs), timeout=backend_timeout)

    resp = request_json(
        base_url,
        "POST",
        "/v1/chat/completions",
        chat_request("wardwright/bakeoff-structured-output", "Return a governed JSON answer."),
        timeout=backend_timeout,
    )

    assert resp.status == 200, f"chat failed status={resp.status} body={resp.body!r}"
    receipt = response_receipt(base_url, resp, timeout=backend_timeout)
    structured = receipt.get("decision", {}).get("structured_output", {})
    guard_events = structured.get("guard_events", [])
    assert structured.get("final_status") == "completed_after_guard"
    assert structured.get("selected_schema") == "answer_v1"
    assert len(guard_events) == 1
    assert guard_events[0]["rule_id"] == "minimum-confidence"
    assert guard_events[0]["guard_type"] == "semantic_validation"
    assert guard_events[0]["attempt_index"] == 0


@pytest.mark.backend
def test_structured_backend_stops_after_global_guard_budget(base_url: str, backend_timeout: float) -> None:
    outputs = ["{not json", "{still not json", "{nope"]
    install_test_config(base_url, structured_output_config(outputs, max_attempts=3), timeout=backend_timeout)

    resp = request_json(
        base_url,
        "POST",
        "/v1/chat/completions",
        chat_request("wardwright/bakeoff-structured-output", "Return a governed JSON answer."),
        timeout=backend_timeout,
    )

    assert resp.status in (400, 422, 502), f"exhausted guard budget must fail closed, got {resp.status}"
    body = resp.body if isinstance(resp.body, dict) else {}
    receipt = body.get("receipt") or body.get("error", {}).get("receipt") or {}
    structured = receipt.get("decision", {}).get("structured_output", {})
    assert structured.get("final_status") == "exhausted_guard_budget"
    assert len(structured.get("guard_events", [])) == 3
    assert structured.get("attempt_count") == 3
