"""Pure TTSR stream simulator for policy authoring and property probes.

This module intentionally has no backend or provider dependency. It models the
contract-level behavior that a UI simulator can later render: chunks arrive,
the governor holds a bounded horizon, detectors inspect held text, and an
arbiter chooses retry or block actions.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from typing import Any, Literal


MatcherKind = Literal["literal", "regex"]
FinalStatus = Literal["completed", "completed_after_retry", "blocked"]


@dataclass(frozen=True)
class TtsrRule:
    id: str
    matcher_kind: MatcherKind
    pattern: str
    horizon_bytes: int
    action: Literal["retry_with_reminder"] = "retry_with_reminder"
    reminder: str = "Revise the response to satisfy the stream governance rule."
    max_retries: int = 1
    on_retry_violation: Literal["block_final"] = "block_final"


@dataclass(frozen=True)
class TtsrAttemptInput:
    chunks: list[str]
    label: str = "attempt"


@dataclass
class TtsrAttemptResult:
    attempt_index: int
    label: str
    triggered: bool
    matched_rule_id: str | None
    action: str | None
    released_text: str
    held_text: str
    trigger_text: str | None
    trigger_span: tuple[int, int] | None
    chunks_seen: int
    timeline: list[dict[str, Any]] = field(default_factory=list)

    def as_counterexample(self) -> dict[str, Any]:
        return {
            "attempt_index": self.attempt_index,
            "label": self.label,
            "triggered": self.triggered,
            "matched_rule_id": self.matched_rule_id,
            "action": self.action,
            "released_text": self.released_text,
            "held_text": self.held_text,
            "trigger_text": self.trigger_text,
            "trigger_span": list(self.trigger_span) if self.trigger_span else None,
            "chunks_seen": self.chunks_seen,
            "timeline": self.timeline,
        }


@dataclass
class TtsrSimulationResult:
    rule: TtsrRule
    status: FinalStatus
    attempts: list[TtsrAttemptResult]
    retry_count: int
    receipt_preview: list[dict[str, Any]]
    validation_warnings: list[str] = field(default_factory=list)

    def as_counterexample(self) -> dict[str, Any]:
        return {
            "rule": {
                "id": self.rule.id,
                "matcher_kind": self.rule.matcher_kind,
                "pattern": self.rule.pattern,
                "horizon_bytes": self.rule.horizon_bytes,
                "action": self.rule.action,
                "max_retries": self.rule.max_retries,
                "on_retry_violation": self.rule.on_retry_violation,
            },
            "status": self.status,
            "retry_count": self.retry_count,
            "validation_warnings": self.validation_warnings,
            "attempts": [attempt.as_counterexample() for attempt in self.attempts],
            "receipt_preview": self.receipt_preview,
        }


@dataclass(frozen=True)
class TtsrScenario:
    name: str
    rule: TtsrRule
    attempts: list[TtsrAttemptInput]
    expected_status: FinalStatus
    expect_first_trigger: bool
    description: str

    def as_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "description": self.description,
            "rule": {
                "id": self.rule.id,
                "matcher_kind": self.rule.matcher_kind,
                "pattern": self.rule.pattern,
                "horizon_bytes": self.rule.horizon_bytes,
                "action": self.rule.action,
                "max_retries": self.rule.max_retries,
                "on_retry_violation": self.rule.on_retry_violation,
            },
            "attempts": [{"label": attempt.label, "chunks": attempt.chunks} for attempt in self.attempts],
            "expected_status": self.expected_status,
            "expect_first_trigger": self.expect_first_trigger,
        }


def utf8_len(text: str) -> int:
    return len(text.encode("utf-8"))


def _release_one_codepoint(held: str) -> tuple[str, str]:
    return held[0], held[1:]


def _compile_matcher(rule: TtsrRule) -> re.Pattern[str]:
    if rule.matcher_kind == "literal":
        return re.compile(re.escape(rule.pattern))
    return re.compile(rule.pattern)


def validate_rule(rule: TtsrRule) -> list[str]:
    warnings: list[str] = []
    if rule.horizon_bytes < 1:
        warnings.append("horizon_bytes must be positive")
    if rule.matcher_kind == "literal" and utf8_len(rule.pattern) > rule.horizon_bytes:
        warnings.append("literal pattern is longer than horizon; trigger bytes may be released before detection")
    if rule.matcher_kind == "regex":
        try:
            re.compile(rule.pattern)
        except re.error as exc:
            warnings.append(f"regex does not compile: {exc}")
        # This is intentionally conservative. The production runtime should use
        # a bounded regex engine; the simulator still flags common authoring
        # shapes that are hard to reason about in a streaming holdback window.
        if re.search(r"(\.\*|\.\+).*(\.\*|\.\+)", rule.pattern):
            warnings.append("regex has multiple broad wildcards; simulation may not bound future-match intent")
    if rule.max_retries < 0:
        warnings.append("max_retries must be non-negative")
    return warnings


def simulate_attempt(rule: TtsrRule, attempt: TtsrAttemptInput, attempt_index: int) -> TtsrAttemptResult:
    matcher = _compile_matcher(rule)
    released = ""
    held = ""
    timeline: list[dict[str, Any]] = []

    for chunk_index, chunk in enumerate(attempt.chunks):
        held += chunk
        timeline.append(
            {
                "type": "chunk_received",
                "attempt_index": attempt_index,
                "chunk_index": chunk_index,
                "text": chunk,
                "held_text": held,
                "held_bytes": utf8_len(held),
                "released_bytes": utf8_len(released),
            }
        )
        match = matcher.search(held)
        if match:
            trigger_text = held[match.start():match.end()]
            timeline.append(
                {
                    "type": "trigger",
                    "attempt_index": attempt_index,
                    "rule_id": rule.id,
                    "chunk_index": chunk_index,
                    "held_span": [match.start(), match.end()],
                    "trigger_text": trigger_text,
                    "released_text_before_abort": released,
                }
            )
            timeline.append(
                {
                    "type": "abort_attempt",
                    "attempt_index": attempt_index,
                    "rule_id": rule.id,
                    "reason": "stream_rule_triggered_before_horizon_release",
                }
            )
            return TtsrAttemptResult(
                attempt_index=attempt_index,
                label=attempt.label,
                triggered=True,
                matched_rule_id=rule.id,
                action=rule.action,
                released_text=released,
                held_text=held,
                trigger_text=trigger_text,
                trigger_span=(match.start(), match.end()),
                chunks_seen=chunk_index + 1,
                timeline=timeline,
            )

        while utf8_len(held) > rule.horizon_bytes:
            released_char, held = _release_one_codepoint(held)
            released += released_char
            timeline.append(
                {
                    "type": "release",
                    "attempt_index": attempt_index,
                    "text": released_char,
                    "released_text": released,
                    "held_text": held,
                    "held_bytes": utf8_len(held),
                }
            )

    while held:
        released_char, held = _release_one_codepoint(held)
        released += released_char
        timeline.append(
            {
                "type": "final_release",
                "attempt_index": attempt_index,
                "text": released_char,
                "released_text": released,
                "held_text": held,
                "held_bytes": utf8_len(held),
            }
        )

    timeline.append({"type": "complete_attempt", "attempt_index": attempt_index, "released_text": released})
    return TtsrAttemptResult(
        attempt_index=attempt_index,
        label=attempt.label,
        triggered=False,
        matched_rule_id=None,
        action=None,
        released_text=released,
        held_text="",
        trigger_text=None,
        trigger_span=None,
        chunks_seen=len(attempt.chunks),
        timeline=timeline,
    )


def simulate_ttsr(rule: TtsrRule, attempts: list[TtsrAttemptInput]) -> TtsrSimulationResult:
    validation_warnings = validate_rule(rule)
    results: list[TtsrAttemptResult] = []
    receipt_preview: list[dict[str, Any]] = []
    retries_used = 0

    for attempt_index, attempt in enumerate(attempts):
        if attempt_index > 0:
            receipt_preview.append(
                {
                    "type": "stream.retry_started",
                    "attempt_index": attempt_index,
                    "rule_id": rule.id,
                    "reminder": rule.reminder,
                }
            )
        result = simulate_attempt(rule, attempt, attempt_index)
        results.append(result)
        if result.triggered:
            receipt_preview.append(
                {
                    "type": "stream.rule_matched",
                    "attempt_index": attempt_index,
                    "rule_id": rule.id,
                    "action": rule.action,
                    "trigger_text": result.trigger_text,
                    "released_to_consumer": False,
                }
            )
            if retries_used < rule.max_retries and attempt_index + 1 < len(attempts):
                retries_used += 1
                continue
            receipt_preview.append(
                {
                    "type": "stream.blocked",
                    "attempt_index": attempt_index,
                    "rule_id": rule.id,
                    "reason": "retry_violation" if retries_used else "stream_rule_triggered",
                }
            )
            return TtsrSimulationResult(
                rule=rule,
                status="blocked",
                attempts=results,
                retry_count=retries_used,
                receipt_preview=receipt_preview,
                validation_warnings=validation_warnings,
            )

        status: FinalStatus = "completed_after_retry" if retries_used else "completed"
        receipt_preview.append(
            {
                "type": "stream.completed",
                "attempt_index": attempt_index,
                "status": status,
                "released_bytes": utf8_len(result.released_text),
            }
        )
        return TtsrSimulationResult(
            rule=rule,
            status=status,
            attempts=results,
            retry_count=retries_used,
            receipt_preview=receipt_preview,
            validation_warnings=validation_warnings,
        )

    return TtsrSimulationResult(
        rule=rule,
        status="completed",
        attempts=results,
        retry_count=retries_used,
        receipt_preview=receipt_preview,
        validation_warnings=validation_warnings,
    )


def split_text(text: str, widths: list[int]) -> list[str]:
    chunks: list[str] = []
    cursor = 0
    for width in widths:
        if cursor >= len(text):
            break
        chunks.append(text[cursor:cursor + width])
        cursor += width
    if cursor < len(text):
        chunks.append(text[cursor:])
    return chunks


def generated_ttsr_scenarios() -> list[TtsrScenario]:
    literal_rule = TtsrRule(
        id="no-old-client",
        matcher_kind="literal",
        pattern="OldClient(",
        horizon_bytes=utf8_len("OldClient("),
        reminder="Use NewClient instead of OldClient.",
    )
    boundary_rule = TtsrRule(
        id="no-old-client-boundary",
        matcher_kind="literal",
        pattern="OldClient(",
        horizon_bytes=utf8_len("OldClient("),
        reminder="Use NewClient instead of OldClient.",
    )
    regex_rule = TtsrRule(
        id="no-api-key-assignment",
        matcher_kind="regex",
        pattern=r"api[_-]?key\s*=",
        horizon_bytes=32,
        reminder="Do not emit API key assignment code.",
    )
    unsafe_horizon_rule = TtsrRule(
        id="unsafe-short-horizon",
        matcher_kind="literal",
        pattern="SECRET",
        horizon_bytes=3,
    )

    return [
        TtsrScenario(
            name="trigger_split_across_chunks",
            description="Literal trigger is divided across provider chunks and must still abort before release.",
            rule=literal_rule,
            attempts=[TtsrAttemptInput(split_text("safe OldClient() tail", [8, 2, 5, 1, 99]))],
            expected_status="blocked",
            expect_first_trigger=True,
        ),
        TtsrScenario(
            name="trigger_at_holdback_boundary_then_retry_success",
            description="Trigger becomes visible exactly when the held window equals the horizon; retry stream passes.",
            rule=boundary_rule,
            attempts=[
                TtsrAttemptInput([*list("OldClient("), ") tail"], "initial"),
                TtsrAttemptInput(["prefix NewClient() tail"], "retry"),
            ],
            expected_status="completed_after_retry",
            expect_first_trigger=True,
        ),
        TtsrScenario(
            name="regex_trigger_split_across_chunks",
            description="Regex trigger intent crosses chunk boundaries.",
            rule=regex_rule,
            attempts=[TtsrAttemptInput(["let ", "api", "_key ", "= ", "value"])],
            expected_status="blocked",
            expect_first_trigger=True,
        ),
        TtsrScenario(
            name="near_miss_releases_normally",
            description="Near miss should not trigger and should release the original stream.",
            rule=literal_rule,
            attempts=[TtsrAttemptInput(["safe OldClients() tail"])],
            expected_status="completed",
            expect_first_trigger=False,
        ),
        TtsrScenario(
            name="retry_violation_blocks_final",
            description="Initial stream triggers, retry triggers again, and final output is blocked.",
            rule=literal_rule,
            attempts=[
                TtsrAttemptInput(["safe Old", "Client()"], "initial"),
                TtsrAttemptInput(["still OldClient()"], "retry"),
            ],
            expected_status="blocked",
            expect_first_trigger=True,
        ),
        TtsrScenario(
            name="unsafe_horizon_counterexample",
            description="A too-short horizon can release trigger bytes before the full literal is detectable.",
            rule=unsafe_horizon_rule,
            attempts=[TtsrAttemptInput(["xxSE", "C", "R", "E", "Tyy"])],
            expected_status="completed",
            expect_first_trigger=False,
        ),
    ]


def run_generated_scenario(scenario: TtsrScenario) -> TtsrSimulationResult:
    return simulate_ttsr(scenario.rule, scenario.attempts)


def scenario_report(scenario: TtsrScenario, result: TtsrSimulationResult) -> dict[str, Any]:
    return {
        "scenario": scenario.as_dict(),
        "result": result.as_counterexample(),
    }


def report_json(report: dict[str, Any]) -> str:
    return json.dumps(report, indent=2, sort_keys=True)
