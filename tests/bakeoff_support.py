from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any


DEFAULT_HEADERS = {
    "Content-Type": "application/json",
    "X-Ingary-Tenant-Id": "bakeoff-tenant",
    "X-Ingary-Application-Id": "bakeoff-suite",
    "X-Ingary-Agent-Id": "bakeoff-agent",
    "X-Ingary-User-Id": "bakeoff-user",
    "X-Ingary-Session-Id": "bakeoff-session",
    "X-Ingary-Run-Id": "bakeoff-run",
}


@dataclass(frozen=True)
class HttpResponse:
    status: int
    headers: dict[str, str]
    body: Any
    elapsed_ms: float


def request_json(
    base_url: str,
    method: str,
    path: str,
    body: Any | None = None,
    *,
    headers: dict[str, str] | None = None,
    timeout: float = 10,
) -> HttpResponse:
    url = urllib.parse.urljoin(base_url.rstrip("/") + "/", path.lstrip("/"))
    merged = dict(DEFAULT_HEADERS)
    if headers:
        merged.update(headers)
    payload = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=payload, method=method, headers=merged)
    started = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            parsed = json.loads(raw.decode("utf-8")) if raw else None
            return HttpResponse(
                resp.status,
                {k.lower(): v for k, v in resp.headers.items()},
                parsed,
                (time.perf_counter() - started) * 1000,
            )
    except urllib.error.HTTPError as err:
        raw = err.read()
        try:
            parsed = json.loads(raw.decode("utf-8")) if raw else None
        except json.JSONDecodeError:
            parsed = raw.decode("utf-8", errors="replace")
        return HttpResponse(
            err.code,
            {k.lower(): v for k, v in err.headers.items()},
            parsed,
            (time.perf_counter() - started) * 1000,
        )


def chat_request(model: str, content: str, *, metadata: dict[str, Any] | None = None) -> dict[str, Any]:
    return {
        "model": model,
        "messages": [{"role": "user", "content": content}],
        "metadata": metadata or {},
    }


def install_test_config(base_url: str, config: dict[str, Any], *, timeout: float = 10) -> None:
    resp = request_json(base_url, "POST", "/__test/config", config, timeout=timeout)
    assert resp.status == 200, (
        "backend must accept the shared bakeoff test config; "
        f"status={resp.status} body={resp.body!r}"
    )


def fetch_receipt(base_url: str, receipt_id: str, *, timeout: float = 10) -> dict[str, Any]:
    resp = request_json(base_url, "GET", f"/v1/receipts/{receipt_id}", timeout=timeout)
    assert resp.status == 200, f"receipt lookup failed status={resp.status} body={resp.body!r}"
    assert isinstance(resp.body, dict), f"receipt body must be an object, got {type(resp.body).__name__}"
    return resp.body


def response_receipt(base_url: str, resp: HttpResponse, *, timeout: float = 10) -> dict[str, Any]:
    receipt_id = resp.headers.get("x-ingary-receipt-id")
    assert receipt_id, f"response missing X-Ingary-Receipt-Id header: headers={resp.headers!r}"
    return fetch_receipt(base_url, receipt_id, timeout=timeout)
