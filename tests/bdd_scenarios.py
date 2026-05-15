#!/usr/bin/env python3
"""BDD-style executable scenarios for Wardwright backend prototypes.

These tests are intentionally plain Python and print Given/When/Then steps so
they double as lightweight behavioral documentation.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable


HEADERS = {
    "Content-Type": "application/json",
    "X-Wardwright-Tenant-Id": "bdd-tenant",
    "X-Wardwright-Application-Id": "bdd-suite",
    "X-Wardwright-Agent-Id": "bdd-agent",
    "X-Wardwright-User-Id": "bdd-user",
    "X-Wardwright-Session-Id": "bdd-session",
    "X-Wardwright-Run-Id": "bdd-run",
}


class ScenarioFailure(AssertionError):
    pass


@dataclass
class Response:
    status: int
    headers: dict[str, str]
    body: Any
    elapsed_ms: float


def step(text: str) -> None:
    print(f"  {text}")


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise ScenarioFailure(message)


def request_json(base_url: str, method: str, path: str, body: Any | None = None, headers: dict[str, str] | None = None) -> Response:
    url = urllib.parse.urljoin(base_url.rstrip("/") + "/", path.lstrip("/"))
    merged = dict(HEADERS)
    if headers:
        merged.update(headers)
    payload = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=payload, method=method, headers=merged)
    started = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read()
            parsed = json.loads(raw.decode("utf-8")) if raw else None
            return Response(resp.status, {k.lower(): v for k, v in resp.headers.items()}, parsed, (time.perf_counter() - started) * 1000)
    except urllib.error.HTTPError as err:
        raw = err.read()
        try:
            parsed = json.loads(raw.decode("utf-8")) if raw else raw.decode("utf-8", errors="replace")
        except json.JSONDecodeError:
            parsed = raw.decode("utf-8", errors="replace")
        return Response(err.code, {k.lower(): v for k, v in err.headers.items()}, parsed, (time.perf_counter() - started) * 1000)


def chat_request(model: str, content: str, metadata: dict[str, Any] | None = None) -> dict[str, Any]:
    return {
        "model": model,
        "messages": [{"role": "user", "content": content}],
        "metadata": metadata or {},
    }


def reset_default_config_if_supported(base_url: str) -> None:
    body = {
        "synthetic_model": "coding-balanced",
        "version": "2026-05-13.mock",
        "targets": [
            {"model": "local/qwen-coder", "context_window": 32768},
            {"model": "managed/kimi-k2.6", "context_window": 262144},
        ],
    }
    resp = request_json(base_url, "POST", "/__test/config", body)
    if resp.status not in (200, 404):
        raise ScenarioFailure(f"default config reset failed: {resp.status} {resp.body}")


def scenario_lists_public_synthetic_models(base_url: str) -> None:
    print("Scenario: listing public synthetic models")
    step("Given an Wardwright backend with the demo synthetic model configured")
    step("When a client lists /v1/models")
    resp = request_json(base_url, "GET", "/v1/models")
    step("Then the response is OpenAI-compatible and contains coding-balanced")
    expect(resp.status == 200, f"expected 200, got {resp.status}")
    expect(resp.body.get("object") == "list", "model list object must be list")
    ids = {item.get("id") for item in resp.body.get("data", [])}
    expect("coding-balanced" in ids or "wardwright/coding-balanced" in ids, "coding-balanced missing")


def scenario_routes_chat_and_records_receipt(base_url: str) -> None:
    print("Scenario: routing a chat request and recording a receipt")
    step("Given a caller sends consuming agent and user headers")
    step("When the caller requests wardwright/coding-balanced")
    chat = request_json(
        base_url,
        "POST",
        "/v1/chat/completions",
        chat_request("wardwright/coding-balanced", "Write a small function."),
    )
    step("Then Wardwright returns a chat completion with receipt headers")
    expect(chat.status == 200, f"expected 200, got {chat.status}: {chat.body}")
    receipt_id = chat.headers.get("x-wardwright-receipt-id")
    selected = chat.headers.get("x-wardwright-selected-model")
    expect(bool(receipt_id), "missing receipt id header")
    expect(bool(selected), "missing selected model header")

    step("And the receipt preserves caller provenance")
    receipt = request_json(base_url, "GET", f"/v1/receipts/{receipt_id}")
    expect(receipt.status == 200, f"expected receipt 200, got {receipt.status}")
    caller = receipt.body.get("caller", {})
    expect(caller.get("consuming_agent_id", {}).get("value") == "bdd-agent", "agent header not retained")
    expect(caller.get("consuming_user_id", {}).get("value") == "bdd-user", "user header not retained")
    expect(receipt.body.get("decision", {}).get("selected_model") == selected, "receipt selected model mismatch")


def scenario_simulates_without_provider_call(base_url: str) -> None:
    print("Scenario: simulating route selection before rollout")
    step("Given an operator wants to preview a request")
    step("When they call /v1/synthetic/simulate")
    resp = request_json(
        base_url,
        "POST",
        "/v1/synthetic/simulate",
        {"request": chat_request("coding-balanced", "Preview this request before activation.")},
    )
    step("Then Wardwright returns a simulated receipt")
    expect(resp.status == 200, f"expected 200, got {resp.status}: {resp.body}")
    receipt = resp.body.get("receipt")
    expect(isinstance(receipt, dict), "simulate response must include receipt")
    expect(receipt.get("final", {}).get("status") == "simulated", "simulate receipt must be simulated")
    expect(receipt.get("attempts", [{}])[0].get("called_provider") is False, "simulation must not call provider")


def scenario_rejects_unknown_model(base_url: str) -> None:
    print("Scenario: rejecting unknown synthetic model names")
    step("Given a caller asks for a model outside Wardwright's public namespace")
    step("When they call /v1/chat/completions")
    resp = request_json(
        base_url,
        "POST",
        "/v1/chat/completions",
        chat_request("not-wardwright/not-real", "Hello"),
    )
    step("Then Wardwright fails closed with a client error")
    expect(resp.status == 400, f"expected 400, got {resp.status}: {resp.body}")


def scenario_dynamic_definition_routes_by_context(base_url: str) -> None:
    print("Scenario: generated model definition routes by context window")
    step("Given a generated synthetic model with small and large targets")
    config = {
        "synthetic_model": "bdd-generated",
        "version": "bdd-1",
        "targets": [
            {"model": "small/model", "context_window": 16},
            {"model": "large/model", "context_window": 1024},
        ],
    }
    cfg = request_json(base_url, "POST", "/__test/config", config)
    if cfg.status == 404:
        step("Then this backend does not support dynamic test config yet; scenario skipped")
        return
    expect(cfg.status == 200, f"test config failed: {cfg.status} {cfg.body}")

    step("When a request exceeds the small model context")
    chat = request_json(
        base_url,
        "POST",
        "/v1/chat/completions",
        chat_request("wardwright/bdd-generated", "x" * 200),
    )
    step("Then Wardwright selects the larger target and records skipped small target")
    expect(chat.status == 200, f"expected 200, got {chat.status}: {chat.body}")
    expect(chat.headers.get("x-wardwright-selected-model") == "large/model", "large target was not selected")
    receipt = request_json(base_url, "GET", f"/v1/receipts/{chat.headers['x-wardwright-receipt-id']}")
    skipped = receipt.body.get("decision", {}).get("skipped", [])
    expect(skipped and skipped[0].get("target") == "small/model", "small target skip not recorded")


def scenario_request_policy_alerts_operator(base_url: str) -> None:
    print("Scenario: request policy creates operator alert receipt events")
    step("Given a synthetic model with a built-in request policy for ambiguous success")
    config = {
        "synthetic_model": "bdd-policy",
        "version": "bdd-policy-1",
        "targets": [{"model": "mock/model", "context_window": 1024}],
        "governance": [
            {
                "id": "ambiguous-success",
                "kind": "request_guard",
                "action": "escalate",
                "contains": "looks done but missing artifact",
                "severity": "warning",
                "message": "Agent appears to be claiming completion without the expected artifact.",
            }
        ],
    }
    cfg = request_json(base_url, "POST", "/__test/config", config)
    if cfg.status == 404:
        step("Then this backend does not support dynamic test config yet; scenario skipped")
        return
    expect(cfg.status == 200, f"test config failed: {cfg.status} {cfg.body}")

    step("When a matching request is simulated")
    resp = request_json(
        base_url,
        "POST",
        "/v1/synthetic/simulate",
        {"request": chat_request("wardwright/bdd-policy", "Looks done but missing artifact for the customer export.")},
    )
    step("Then the receipt records a policy action and alert event")
    expect(resp.status == 200, f"expected 200, got {resp.status}: {resp.body}")
    receipt = resp.body.get("receipt", {})
    actions = receipt.get("decision", {}).get("policy_actions", [])
    final = receipt.get("final", {})
    events = final.get("events", [])
    expect(any(action.get("rule_id") == "ambiguous-success" for action in actions), "policy action missing")
    expect(final.get("alert_count") == 1, "alert count missing")
    expect(any(event.get("type") == "policy.alert" for event in events), "policy alert event missing")


SCENARIOS: list[Callable[[str], None]] = [
    scenario_lists_public_synthetic_models,
    scenario_routes_chat_and_records_receipt,
    scenario_simulates_without_provider_call,
    scenario_rejects_unknown_model,
    scenario_dynamic_definition_routes_by_context,
    scenario_request_policy_alerts_operator,
]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:8787")
    args = parser.parse_args()
    failures: list[str] = []
    try:
        reset_default_config_if_supported(args.base_url)
    except Exception as exc:  # noqa: BLE001
        failures.append(f"reset_default_config: {exc}")
    for scenario in SCENARIOS:
        try:
            scenario(args.base_url)
            print("  PASS\n")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"{scenario.__name__}: {exc}")
            print(f"  FAIL: {exc}\n", file=sys.stderr)
    if failures:
        print("FAILED SCENARIOS", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
