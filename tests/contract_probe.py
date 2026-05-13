#!/usr/bin/env python3
"""HTTP contract and fuzz probe for Ingary backend prototypes.

This is intentionally dependency-free so every prototype can run it before we
choose a language or framework. It is not a replacement for generated OpenAPI
tests; it is the first shared behavioral gate.
"""

from __future__ import annotations

import argparse
import json
import random
import statistics
import string
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any


DEFAULT_HEADERS = {
    "Content-Type": "application/json",
    "X-Ingary-Tenant-Id": "contract-tenant",
    "X-Ingary-Application-Id": "contract-probe",
    "X-Ingary-Agent-Id": "contract-agent",
    "X-Ingary-User-Id": "contract-user",
    "X-Ingary-Session-Id": "contract-session",
    "X-Ingary-Run-Id": "contract-run",
    "X-Client-Request-Id": "contract-request",
}


@dataclass
class ProbeResult:
    method: str
    path: str
    status: int
    elapsed_ms: float
    body: Any
    headers: dict[str, str]


class ProbeFailure(AssertionError):
    pass


def request_json(
    base_url: str,
    method: str,
    path: str,
    body: Any | None = None,
    headers: dict[str, str] | None = None,
    timeout: float = 10.0,
) -> ProbeResult:
    url = urllib.parse.urljoin(base_url.rstrip("/") + "/", path.lstrip("/"))
    merged_headers = dict(DEFAULT_HEADERS)
    if headers:
        merged_headers.update(headers)
    payload = None
    if body is not None:
        payload = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=payload, method=method, headers=merged_headers)
    started = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            elapsed_ms = (time.perf_counter() - started) * 1000
            parsed = json.loads(raw.decode("utf-8")) if raw else None
            return ProbeResult(
                method=method,
                path=path,
                status=resp.status,
                elapsed_ms=elapsed_ms,
                body=parsed,
                headers={k.lower(): v for k, v in resp.headers.items()},
            )
    except urllib.error.HTTPError as err:
        raw = err.read()
        elapsed_ms = (time.perf_counter() - started) * 1000
        try:
            parsed = json.loads(raw.decode("utf-8")) if raw else None
        except json.JSONDecodeError:
            parsed = raw.decode("utf-8", errors="replace")
        return ProbeResult(
            method=method,
            path=path,
            status=err.code,
            elapsed_ms=elapsed_ms,
            body=parsed,
            headers={k.lower(): v for k, v in err.headers.items()},
        )


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise ProbeFailure(message)


def random_text(rng: random.Random, approx_chars: int) -> str:
    words = []
    alphabet = string.ascii_lowercase
    while sum(len(w) + 1 for w in words) < approx_chars:
        size = rng.randint(3, 12)
        words.append("".join(rng.choice(alphabet) for _ in range(size)))
    return " ".join(words)


def prompt_chars_for_case(rng: random.Random, case: int) -> int:
    if case % 7 == 0:
        return rng.randint(1, 40)
    if case % 7 == 1:
        return rng.randint(100, 1000)
    if case % 7 == 2:
        return rng.randint(4000, 10000)
    return rng.randint(20, 3000)


def chat_body(model: str, text: str, stream: bool = False) -> dict[str, Any]:
    return {
        "model": model,
        "stream": stream,
        "messages": [
            {"role": "system", "content": "You are a contract-test mock."},
            {"role": "user", "content": text},
        ],
        "metadata": {
            "tenant_id": "metadata-tenant",
            "application_id": "metadata-app",
            "consuming_agent_id": "metadata-agent",
            "consuming_user_id": "metadata-user",
            "session_id": "metadata-session",
            "run_id": "metadata-run",
            "tags": ["contract", "fuzz"],
        },
    }


def assert_model_list(result: ProbeResult) -> None:
    expect(result.status == 200, f"/v1/models status {result.status}")
    expect(result.body.get("object") == "list", "/v1/models object must be list")
    data = result.body.get("data")
    expect(isinstance(data, list) and data, "/v1/models data must be non-empty list")
    ids = {item.get("id") for item in data if isinstance(item, dict)}
    expect(
        "coding-balanced" in ids or "ingary/coding-balanced" in ids,
        "/v1/models must expose coding-balanced or ingary/coding-balanced",
    )


def assert_chat_response(result: ProbeResult, requested_model: str) -> str:
    expect(result.status == 200, f"chat status {result.status}: {result.body}")
    body = result.body
    expect(body.get("object") == "chat.completion", "chat object must be chat.completion")
    expect("id" in body, "chat response must include id")
    expect(body.get("model"), "chat response must include model")
    expect(isinstance(body.get("choices"), list), "chat response choices must be a list")
    receipt_id = result.headers.get("x-ingary-receipt-id")
    expect(receipt_id, "chat response must include X-Ingary-Receipt-Id")
    selected = result.headers.get("x-ingary-selected-model")
    expect(selected, "chat response must include X-Ingary-Selected-Model")
    expect(
        requested_model in ("coding-balanced", "ingary/coding-balanced"),
        "probe only expects known model namespace variants",
    )
    return receipt_id or ""


def assert_receipt(result: ProbeResult, receipt_id: str) -> None:
    expect(result.status == 200, f"receipt {receipt_id} status {result.status}")
    body = result.body
    expect(body.get("receipt_id") == receipt_id, "receipt_id mismatch")
    expect(body.get("synthetic_model") in ("coding-balanced", "ingary/coding-balanced"), "bad synthetic_model")
    caller = body.get("caller")
    expect(isinstance(caller, dict), "receipt must include caller object")
    agent = caller.get("consuming_agent_id")
    expect(isinstance(agent, dict), "caller.consuming_agent_id must be sourced object")
    expect(agent.get("value") == "contract-agent", "header caller agent must win over metadata")
    expect(agent.get("source") in ("header", "trusted_auth"), "caller agent source must be explicit")
    decision = body.get("decision")
    expect(isinstance(decision, dict), "receipt must include decision")
    attempts = body.get("attempts")
    expect(isinstance(attempts, list) and attempts, "receipt must include non-empty attempts")
    final = body.get("final")
    expect(isinstance(final, dict), "receipt must include final")


def assert_receipt_search(result: ProbeResult) -> None:
    expect(result.status == 200, f"receipt search status {result.status}")
    data = result.body.get("data")
    expect(isinstance(data, list), "receipt search data must be list")


def run_probe(base_url: str, fuzz_runs: int, seed: int) -> int:
    rng = random.Random(seed)
    latencies: dict[str, list[float]] = {
        "models": [],
        "chat": [],
        "simulate": [],
        "receipt": [],
        "receipt_search": [],
        "admin": [],
    }
    failures: list[str] = []

    def record(kind: str, result: ProbeResult) -> ProbeResult:
        latencies[kind].append(result.elapsed_ms)
        return result

    checks: list[tuple[str, Any]] = []
    try:
        checks.append(("models", assert_model_list(record("models", request_json(base_url, "GET", "/v1/models")))))
    except Exception as exc:  # noqa: BLE001 - probe reports all failures uniformly.
        failures.append(f"models: {exc}")

    receipt_ids: list[str] = []
    for i in range(fuzz_runs):
        model = "coding-balanced" if i % 2 == 0 else "ingary/coding-balanced"
        text = random_text(rng, prompt_chars_for_case(rng, i))
        body = chat_body(model, text)
        try:
            chat = record("chat", request_json(base_url, "POST", "/v1/chat/completions", body))
            receipt_id = assert_chat_response(chat, model)
            receipt_ids.append(receipt_id)
            receipt = record("receipt", request_json(base_url, "GET", f"/v1/receipts/{receipt_id}"))
            assert_receipt(receipt, receipt_id)
            sim = record("simulate", request_json(base_url, "POST", "/v1/synthetic/simulate", {"request": body}))
            expect(sim.status == 200, f"simulate status {sim.status}: {sim.body}")
            expect(isinstance(sim.body.get("receipt"), dict), "simulate response must include receipt")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"fuzz[{i}] model={model}: {exc}")

    try:
        query = "/v1/receipts?consuming_agent_id=contract-agent&limit=20"
        assert_receipt_search(record("receipt_search", request_json(base_url, "GET", query)))
    except Exception as exc:  # noqa: BLE001
        failures.append(f"receipt_search: {exc}")

    for path in ("/admin/providers", "/admin/synthetic-models"):
        try:
            result = record("admin", request_json(base_url, "GET", path))
            expect(result.status == 200, f"{path} status {result.status}")
            expect(isinstance(result.body.get("data"), list), f"{path} data must be list")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"{path}: {exc}")

    print(f"base_url={base_url} seed={seed} fuzz_runs={fuzz_runs} receipts={len(receipt_ids)}")
    for kind, values in latencies.items():
        if not values:
            continue
        p50 = statistics.median(values)
        p95 = sorted(values)[max(0, int(len(values) * 0.95) - 1)]
        print(f"{kind:14s} count={len(values):3d} p50_ms={p50:8.2f} p95_ms={p95:8.2f} max_ms={max(values):8.2f}")

    if failures:
        print("\nFAILURES", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:8787")
    parser.add_argument("--fuzz-runs", type=int, default=25)
    parser.add_argument("--seed", type=int, default=20260513)
    args = parser.parse_args()
    return run_probe(args.base_url, args.fuzz_runs, args.seed)


if __name__ == "__main__":
    raise SystemExit(main())
