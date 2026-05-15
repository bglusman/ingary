#!/usr/bin/env python3
"""Generated model/governance property tests for Wardwright prototypes.

The harness has two layers:

1. Pure local properties for generated model definitions and stream governance
   state transitions.
2. Optional HTTP properties against a backend that implements the prototype-only
   `POST /__test/config` endpoint.

It intentionally uses the Python standard library. The goal is to make the
first acceptance tests portable across Rust, Go, Elixir, and future prototypes.
"""

from __future__ import annotations

import argparse
import json
import random
import re
import string
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any

from ttsr_simulator import (
    TtsrAttemptInput,
    TtsrRule,
    generated_ttsr_scenarios,
    report_json,
    run_generated_scenario,
    simulate_attempt,
    simulate_ttsr,
    split_text,
    utf8_len,
)


HEADERS = {
    "Content-Type": "application/json",
    "X-Wardwright-Tenant-Id": "property-tenant",
    "X-Wardwright-Application-Id": "property-fuzzer",
    "X-Wardwright-Agent-Id": "property-agent",
    "X-Wardwright-User-Id": "property-user",
    "X-Wardwright-Session-Id": "property-session",
    "X-Wardwright-Run-Id": "property-run",
}


@dataclass(frozen=True)
class Target:
    model: str
    context_window: int


@dataclass(frozen=True)
class ModelDef:
    synthetic_model: str
    version: str
    targets: list[Target]
    stream_rules: list[dict[str, str]]
    governance: list[dict[str, str]]


class FuzzFailure(AssertionError):
    pass


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise FuzzFailure(message)


def request_json(base_url: str, method: str, path: str, body: Any | None = None) -> tuple[int, dict[str, str], Any, float]:
    url = urllib.parse.urljoin(base_url.rstrip("/") + "/", path.lstrip("/"))
    payload = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=payload, method=method, headers=HEADERS)
    started = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read()
            elapsed = (time.perf_counter() - started) * 1000
            parsed = json.loads(raw.decode("utf-8")) if raw else None
            return resp.status, {k.lower(): v for k, v in resp.headers.items()}, parsed, elapsed
    except urllib.error.HTTPError as err:
        raw = err.read()
        elapsed = (time.perf_counter() - started) * 1000
        try:
            parsed = json.loads(raw.decode("utf-8")) if raw else None
        except json.JSONDecodeError:
            parsed = raw.decode("utf-8", errors="replace")
        return err.code, {k.lower(): v for k, v in err.headers.items()}, parsed, elapsed


def generated_model(rng: random.Random, index: int) -> ModelDef:
    target_count = rng.randint(2, 6)
    windows = sorted(rng.sample(range(64, 12000), target_count))
    targets = [
        Target(model=f"provider{i}/model-{index}-{i}", context_window=window)
        for i, window in enumerate(windows)
    ]
    forbidden = f"FORBIDDEN_{index}_{rng.randint(100, 999)}"
    alert_marker = f"ALERT_{index}_{rng.randint(100, 999)}"
    return ModelDef(
        synthetic_model=f"fuzz-model-{index}",
        version=f"fuzz-{index}",
        targets=targets,
        stream_rules=[
            {
                "id": f"no-{forbidden.lower()}",
                "pattern": forbidden,
                "action": "block_final",
            }
        ],
        governance=[
            {
                "id": f"alert-{alert_marker.lower()}",
                "kind": "request_guard",
                "action": "escalate",
                "contains": alert_marker,
                "severity": "warning",
                "message": "generated request matched alert policy",
            }
        ],
    )


def model_config_payload(model: ModelDef) -> dict[str, Any]:
    return {
        "synthetic_model": model.synthetic_model,
        "version": model.version,
        "targets": [
            {"model": target.model, "context_window": target.context_window}
            for target in model.targets
        ],
        "stream_rules": model.stream_rules,
        "governance": model.governance,
    }


def oracle_select(model: ModelDef, estimated_tokens: int) -> tuple[str, list[dict[str, Any]]]:
    skipped: list[dict[str, Any]] = []
    for target in sorted(model.targets, key=lambda t: (t.context_window, t.model)):
        if target.context_window >= estimated_tokens:
            return target.model, skipped
        skipped.append(
            {
                "target": target.model,
                "reason": "context_window_too_small",
                "context_window": target.context_window,
            }
        )
    return max(model.targets, key=lambda t: (t.context_window, t.model)).model, skipped


def approx_text_for_estimate(estimated_tokens: int) -> str:
    # Prototype estimators currently use roughly ceil(chars / 4) plus role text.
    chars = max(1, estimated_tokens * 4 - 20)
    alphabet = string.ascii_lowercase
    return "".join(alphabet[i % len(alphabet)] for i in range(chars))


def chat_body(model_id: str, estimated_tokens: int) -> dict[str, Any]:
    return {
        "model": model_id,
        "messages": [
            {"role": "system", "content": "property test"},
            {"role": "user", "content": approx_text_for_estimate(estimated_tokens)},
        ],
        "metadata": {
            "consuming_agent_id": "metadata-agent",
            "consuming_user_id": "metadata-user",
            "session_id": "metadata-session",
            "tags": ["property"],
        },
    }


def estimate_like_prototypes(body: dict[str, Any]) -> int:
    chars = 0
    for msg in body["messages"]:
        chars += len(msg.get("role", ""))
        content = msg.get("content")
        if isinstance(content, str):
            chars += len(content)
        else:
            chars += len(json.dumps(content))
    return max(1, (chars + 3) // 4)


def receipt_selected(receipt: dict[str, Any]) -> str:
    decision = receipt.get("decision", {})
    return decision.get("selected_model") or decision.get("selected")


def receipt_skipped(receipt: dict[str, Any]) -> list[dict[str, Any]]:
    skipped = receipt.get("decision", {}).get("skipped", [])
    return skipped if isinstance(skipped, list) else []


def pure_route_properties(rng: random.Random, cases: int) -> None:
    for i in range(cases):
        model = generated_model(rng, i)
        windows = [target.context_window for target in model.targets]
        estimates = {1, min(windows), max(windows), max(windows) + 1}
        for window in windows:
            estimates.update({max(1, window - 1), window, window + 1})
        for estimate in sorted(estimates):
            selected, skipped = oracle_select(model, estimate)
            selected_target = next(t for t in model.targets if t.model == selected)
            if estimate <= max(windows):
                expect(selected_target.context_window >= estimate, "oracle selected target too small")
                smaller_fit = [
                    t for t in model.targets
                    if t.context_window >= estimate and t.context_window < selected_target.context_window
                ]
                expect(not smaller_fit, "oracle did not pick smallest eligible target")
            expect(
                all(item["context_window"] < estimate for item in skipped),
                "oracle skipped target that actually fit",
            )


def stream_governance_oracle(rng: random.Random, cases: int) -> None:
    for i in range(cases):
        marker = f"DENY_{i}_{rng.randint(1000, 9999)}"
        prefix = "safe-" * rng.randint(0, 12)
        suffix = "-tail" * rng.randint(0, 12)
        violating = rng.choice([True, False])
        stream = prefix + (marker if violating else "allowed") + suffix
        # A regex horizon smaller than the pattern cannot guarantee
        # non-release-before-detection. Product config validation should enforce
        # the same class of invariant for literal/regex rules with known
        # minimum match lengths.
        buffer_size = rng.randint(len(marker), len(marker) + 32)
        released = ""
        window = ""
        triggered = False

        for ch in stream:
            window += ch
            if re.search(re.escape(marker), window):
                triggered = True
                break
            if len(window) > buffer_size:
                released += window[0]
                window = window[1:]

        if violating:
            expect(triggered, "violating stream did not trigger rule")
            expect(marker not in released, "violating marker was released before trigger")
        else:
            expect(not triggered, "non-violating stream triggered rule")


def ttsr_scenario_properties() -> list[dict[str, Any]]:
    reports: list[dict[str, Any]] = []
    for scenario in generated_ttsr_scenarios():
        result = run_generated_scenario(scenario)
        reports.append({"scenario": scenario.as_dict(), "result": result.as_counterexample()})
        first_attempt = result.attempts[0]
        expect(
            result.status == scenario.expected_status,
            f"TTSR scenario {scenario.name} status mismatch:\n{report_json(reports[-1])}",
        )
        expect(
            first_attempt.triggered == scenario.expect_first_trigger,
            f"TTSR scenario {scenario.name} first trigger mismatch:\n{report_json(reports[-1])}",
        )
        if first_attempt.triggered:
            expect(
                first_attempt.trigger_text not in first_attempt.released_text,
                f"TTSR scenario {scenario.name} released trigger before abort:\n{report_json(reports[-1])}",
            )
            expect(
                any(event["type"] == "stream.rule_matched" for event in result.receipt_preview),
                f"TTSR scenario {scenario.name} did not preview rule receipt event",
            )
        if scenario.name == "unsafe_horizon_counterexample":
            expect(result.validation_warnings, "unsafe horizon scenario did not explain the authoring risk")
            expect(
                "SECRET" in first_attempt.released_text and not first_attempt.triggered,
                "unsafe horizon counterexample did not release the undetected trigger",
            )
    return reports


def ttsr_stream_properties(rng: random.Random, cases: int) -> None:
    alphabet = string.ascii_letters + string.digits
    for i in range(cases):
        marker = "TRIP" + "".join(rng.choice(alphabet) for _ in range(rng.randint(3, 12)))
        prefix = "".join(rng.choice("safe-_ ") for _ in range(rng.randint(0, 24)))
        suffix = "".join(rng.choice("tail-_ ") for _ in range(rng.randint(0, 24)))
        stream = prefix + marker + suffix
        cut_points = sorted(rng.sample(range(1, len(stream)), rng.randint(1, min(5, len(stream) - 1)))) if len(stream) > 1 else []
        widths: list[int] = []
        cursor = 0
        for cut_point in cut_points:
            widths.append(cut_point - cursor)
            cursor = cut_point
        widths.append(len(stream) - cursor)
        chunks = split_text(stream, widths)
        rule = TtsrRule(
            id=f"generated-ttsr-{i}",
            matcher_kind=rng.choice(["literal", "regex"]),
            pattern=marker if rng.random() < 0.7 else re.escape(marker),
            horizon_bytes=utf8_len(marker) + rng.randint(0, 24),
            max_retries=1,
        )
        if rule.matcher_kind == "regex":
            rule = TtsrRule(
                id=rule.id,
                matcher_kind="regex",
                pattern=re.escape(marker),
                horizon_bytes=rule.horizon_bytes,
                max_retries=rule.max_retries,
            )
        attempt_result = simulate_attempt(rule, TtsrAttemptInput(chunks), 0)
        expect(attempt_result.triggered, f"TTSR generated stream did not trigger for {marker!r}")
        expect(
            marker not in attempt_result.released_text,
            f"TTSR generated stream released marker before abort: {attempt_result.as_counterexample()}",
        )
        expect(
            attempt_result.chunks_seen <= len(chunks),
            "TTSR generated stream consumed more chunks than provided",
        )

        near_replacements = [candidate for candidate in [")", "_", "x"] if candidate != marker[-1]]
        near_miss = prefix + marker[:-1] + rng.choice(near_replacements) + suffix
        near_chunks = split_text(near_miss, widths)
        near_result = simulate_attempt(
            TtsrRule(
                id=f"generated-ttsr-near-{i}",
                matcher_kind="literal",
                pattern=marker,
                horizon_bytes=utf8_len(marker) + rng.randint(0, 24),
            ),
            TtsrAttemptInput(near_chunks),
            0,
        )
        expect(not near_result.triggered, f"TTSR near miss triggered for {marker!r}")
        expect(near_result.released_text == near_miss, "TTSR near miss did not release original stream")

        retry_result = simulate_ttsr(
            TtsrRule(
                id=f"generated-ttsr-retry-{i}",
                matcher_kind="literal",
                pattern=marker,
                horizon_bytes=utf8_len(marker),
                max_retries=1,
            ),
            [TtsrAttemptInput(chunks, "initial"), TtsrAttemptInput(chunks, "retry")],
        )
        expect(retry_result.status == "blocked", "TTSR retry violation did not block final output")
        expect(retry_result.retry_count == 1, "TTSR retry violation did not record exactly one retry")
        expect(
            sum(1 for event in retry_result.receipt_preview if event["type"] == "stream.rule_matched") == 2,
            "TTSR retry violation did not record both matches",
        )


def policy_cache_eviction_oracle(rng: random.Random, cases: int) -> None:
    for _i in range(cases):
        capacity = rng.randint(1, 20)
        timestamps = [rng.randint(0, 50) for _ in range(rng.randint(0, 80))]
        inserted = [(index + 1, timestamp) for index, timestamp in enumerate(timestamps)]
        expected = set(
            sequence
            for sequence, _timestamp in sorted(inserted, key=lambda item: (item[1], item[0]))[-capacity:]
        )
        expect(len(expected) <= capacity, "cache oracle kept more events than capacity")
        if inserted:
            oldest = sorted(inserted, key=lambda item: (item[1], item[0]))[: max(0, len(inserted) - capacity)]
            expect(not any(sequence in expected for sequence, _timestamp in oldest), "cache oracle retained an evicted event")


def configure_backend(base_url: str, model: ModelDef) -> bool:
    status, _headers, body, _elapsed = request_json(base_url, "POST", "/__test/config", model_config_payload(model))
    if status == 404:
        return False
    expect(status == 200, f"/__test/config failed: {status} {body}")
    return True


def http_dynamic_properties(base_url: str, rng: random.Random, cases: int) -> tuple[int, list[float]]:
    latencies: list[float] = []
    executed = 0
    for i in range(cases):
        model = generated_model(rng, i)
        if not configure_backend(base_url, model):
            print("backend does not support /__test/config; skipped HTTP dynamic properties")
            return executed, latencies
        windows = [target.context_window for target in model.targets]
        estimates = [
            max(1, rng.choice(windows) - 1),
            rng.choice(windows),
            rng.choice(windows) + 1,
            max(windows) + rng.randint(1, 10),
        ]
        for estimate in estimates:
            body = chat_body(rng.choice([model.synthetic_model, f"wardwright/{model.synthetic_model}"]), estimate)
            actual_estimate = estimate_like_prototypes(body)
            expected, expected_skipped = oracle_select(model, actual_estimate)
            status, headers, response, elapsed = request_json(base_url, "POST", "/v1/chat/completions", body)
            latencies.append(elapsed)
            expect(status == 200, f"chat failed: {status} {response}")
            receipt_id = headers.get("x-wardwright-receipt-id")
            expect(bool(receipt_id), "missing receipt header")
            expect(headers.get("x-wardwright-selected-model") == expected, "selected-model header mismatched oracle")
            status, _headers, receipt, _elapsed = request_json(base_url, "GET", f"/v1/receipts/{receipt_id}")
            expect(status == 200, f"receipt lookup failed: {status} {receipt}")
            expect(receipt_selected(receipt) == expected, "receipt selected model mismatched oracle")
            skipped = receipt_skipped(receipt)
            expect(len(skipped) == len(expected_skipped), "receipt skipped list length mismatched oracle")
            caller = receipt.get("caller", {})
            expect(caller.get("consuming_agent_id", {}).get("value") == "property-agent", "caller header not retained")
            executed += 1
        marker = model.governance[0]["contains"]
        body = chat_body(f"wardwright/{model.synthetic_model}", min(windows))
        body["messages"].append({"role": "user", "content": f"operator should see {marker}"})
        status, _headers, response, elapsed = request_json(
            base_url,
            "POST",
            "/v1/synthetic/simulate",
            {"request": body},
        )
        latencies.append(elapsed)
        expect(status == 200, f"simulate policy failed: {status} {response}")
        receipt = response.get("receipt", {})
        actions = receipt.get("decision", {}).get("policy_actions", [])
        final = receipt.get("final", {})
        expect(any(action.get("matched") for action in actions), "matching generated policy did not record action")
        expect(final.get("alert_count") == 1, "matching generated policy did not increment alert count")
        expect(any(event.get("type") == "policy.alert" for event in final.get("events", [])), "matching generated policy did not emit alert event")
        executed += 1
    return executed, latencies


def http_policy_cache_properties(base_url: str, rng: random.Random, cases: int) -> tuple[int, list[float]]:
    latencies: list[float] = []
    executed = 0
    for i in range(cases):
        model = generated_model(rng, 10_000 + i)
        payload = model_config_payload(model)
        payload["policy_cache"] = {"max_entries": 8, "recent_limit": 8}
        payload["governance"] = [
            {
                "id": "repeat-tool",
                "kind": "history_threshold",
                "action": "escalate",
                "cache_kind": "tool_call",
                "cache_key": "shell:ls",
                "cache_scope": "session_id",
                "threshold": 2,
                "severity": "warning",
            }
        ]
        status, _headers, body, elapsed = request_json(base_url, "POST", "/__test/config", payload)
        latencies.append(elapsed)
        if status == 404:
            print("backend does not support /__test/config; skipped HTTP policy cache properties")
            return executed, latencies
        expect(status == 200, f"/__test/config for policy cache failed: {status} {body}")

        for session_id in ["property-session", "other-session"]:
            status, _headers, body, elapsed = request_json(
                base_url,
                "POST",
                "/v1/policy-cache/events",
                {
                    "kind": "tool_call",
                    "key": "shell:ls",
                    "scope": {"session_id": session_id},
                    "created_at_unix_ms": rng.randint(0, 50),
                },
            )
            latencies.append(elapsed)
            expect(status == 201, f"policy cache event insert failed: {status} {body}")

        request = chat_body(model.synthetic_model, min(target.context_window for target in model.targets))
        status, _headers, response, elapsed = request_json(base_url, "POST", "/v1/synthetic/simulate", {"request": request})
        latencies.append(elapsed)
        expect(status == 200, f"policy cache miss simulate failed: {status} {response}")
        expect(response["receipt"]["final"]["alert_count"] == 0, "policy cache counted another session")

        status, _headers, body, elapsed = request_json(
            base_url,
            "POST",
            "/v1/policy-cache/events",
            {
                "kind": "tool_call",
                "key": "shell:ls",
                "scope": {"session_id": "property-session"},
                "created_at_unix_ms": rng.randint(0, 50),
            },
        )
        latencies.append(elapsed)
        expect(status == 201, f"second policy cache event insert failed: {status} {body}")

        status, _headers, response, elapsed = request_json(base_url, "POST", "/v1/synthetic/simulate", {"request": request})
        latencies.append(elapsed)
        expect(status == 200, f"policy cache hit simulate failed: {status} {response}")
        receipt = response["receipt"]
        expect(receipt["final"]["alert_count"] == 1, "policy cache threshold did not alert")
        actions = receipt.get("decision", {}).get("policy_actions", [])
        expect(actions and actions[0].get("history_count") == 2, "policy cache action did not report matching count")
        executed += 1
    return executed, latencies


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default=None, help="Backend URL for HTTP dynamic properties.")
    parser.add_argument("--cases", type=int, default=100)
    parser.add_argument("--http-cases", type=int, default=25)
    parser.add_argument("--seed", type=int, default=20260513)
    parser.add_argument("--show-ttsr-examples", action="store_true", help="Print generated TTSR scenario reports as JSON.")
    args = parser.parse_args()

    rng = random.Random(args.seed)
    pure_route_properties(rng, args.cases)
    stream_governance_oracle(rng, args.cases)
    ttsr_reports = ttsr_scenario_properties()
    ttsr_stream_properties(rng, args.cases)
    policy_cache_eviction_oracle(rng, args.cases)
    if args.show_ttsr_examples:
        print(f"pure properties passed cases={args.cases} seed={args.seed}", file=sys.stderr)
        print(json.dumps({"ttsr_examples": ttsr_reports}, indent=2, sort_keys=True))
    else:
        print(f"pure properties passed cases={args.cases} seed={args.seed}")

    if args.base_url:
        executed, latencies = http_dynamic_properties(args.base_url, rng, args.http_cases)
        cache_executed, cache_latencies = http_policy_cache_properties(args.base_url, rng, args.http_cases)
        executed += cache_executed
        latencies.extend(cache_latencies)
        if executed:
            latencies_sorted = sorted(latencies)
            p50 = latencies_sorted[len(latencies_sorted) // 2]
            p95 = latencies_sorted[max(0, int(len(latencies_sorted) * 0.95) - 1)]
            print(
                f"http dynamic properties passed requests={executed} "
                f"p50_ms={p50:.2f} p95_ms={p95:.2f} max_ms={max(latencies):.2f}"
            )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except FuzzFailure as exc:
        print(f"property failure: {exc}", file=sys.stderr)
        raise SystemExit(1)
