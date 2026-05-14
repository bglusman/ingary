#!/usr/bin/env python3
"""Generated model/governance property tests for Ingary prototypes.

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


HEADERS = {
    "Content-Type": "application/json",
    "X-Ingary-Tenant-Id": "property-tenant",
    "X-Ingary-Application-Id": "property-fuzzer",
    "X-Ingary-Agent-Id": "property-agent",
    "X-Ingary-User-Id": "property-user",
    "X-Ingary-Session-Id": "property-session",
    "X-Ingary-Run-Id": "property-run",
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
            body = chat_body(rng.choice([model.synthetic_model, f"ingary/{model.synthetic_model}"]), estimate)
            actual_estimate = estimate_like_prototypes(body)
            expected, expected_skipped = oracle_select(model, actual_estimate)
            status, headers, response, elapsed = request_json(base_url, "POST", "/v1/chat/completions", body)
            latencies.append(elapsed)
            expect(status == 200, f"chat failed: {status} {response}")
            receipt_id = headers.get("x-ingary-receipt-id")
            expect(bool(receipt_id), "missing receipt header")
            expect(headers.get("x-ingary-selected-model") == expected, "selected-model header mismatched oracle")
            status, _headers, receipt, _elapsed = request_json(base_url, "GET", f"/v1/receipts/{receipt_id}")
            expect(status == 200, f"receipt lookup failed: {status} {receipt}")
            expect(receipt_selected(receipt) == expected, "receipt selected model mismatched oracle")
            skipped = receipt_skipped(receipt)
            expect(len(skipped) == len(expected_skipped), "receipt skipped list length mismatched oracle")
            caller = receipt.get("caller", {})
            expect(caller.get("consuming_agent_id", {}).get("value") == "property-agent", "caller header not retained")
            executed += 1
        marker = model.governance[0]["contains"]
        body = chat_body(f"ingary/{model.synthetic_model}", min(windows))
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default=None, help="Backend URL for HTTP dynamic properties.")
    parser.add_argument("--cases", type=int, default=100)
    parser.add_argument("--http-cases", type=int, default=25)
    parser.add_argument("--seed", type=int, default=20260513)
    args = parser.parse_args()

    rng = random.Random(args.seed)
    pure_route_properties(rng, args.cases)
    stream_governance_oracle(rng, args.cases)
    print(f"pure properties passed cases={args.cases} seed={args.seed}")

    if args.base_url:
        executed, latencies = http_dynamic_properties(args.base_url, rng, args.http_cases)
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
