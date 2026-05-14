from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from typing import Any

import pytest


pytestmark = pytest.mark.live_llm


def live_llm_config() -> tuple[str, str, dict[str, str]]:
    if os.environ.get("INGARY_LIVE_LLM") != "1":
        pytest.skip("set INGARY_LIVE_LLM=1 to run live LLM smoke tests")
    model = os.environ.get("INGARY_LIVE_LLM_MODEL")
    if not model:
        pytest.skip("set INGARY_LIVE_LLM_MODEL to run live LLM smoke tests")
    base_url = os.environ.get("INGARY_LIVE_LLM_BASE_URL", "http://127.0.0.1:11434/v1")
    headers = {"Content-Type": "application/json"}
    api_key = os.environ.get("INGARY_LIVE_LLM_API_KEY")
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    return base_url.rstrip("/"), model, headers


def chat_completion(messages: list[dict[str, str]], *, temperature: float = 0.7) -> str:
    base_url, model, headers = live_llm_config()
    payload = json.dumps(
        {
            "model": model,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": 400,
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        f"{base_url}/chat/completions",
        data=payload,
        method="POST",
        headers=headers,
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body: Any = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise AssertionError(f"live LLM request failed status={exc.code} body={detail}") from exc
    content = body.get("choices", [{}])[0].get("message", {}).get("content")
    assert isinstance(content, str) and content.strip(), f"live LLM returned no content: {body!r}"
    return content


def classify_json_like_output(text: str) -> dict[str, Any]:
    stripped = text.strip()
    try:
        parsed = json.loads(stripped)
        return {"kind": "json", "parsed_type": type(parsed).__name__}
    except json.JSONDecodeError as exc:
        return {
            "kind": "non_json",
            "has_fence": "```" in text,
            "has_brace": "{" in text or "}" in text,
            "mentions_refusal": "cannot" in text.lower() or "can't" in text.lower(),
            "error": exc.msg,
        }


def test_live_llm_structured_output_smoke() -> None:
    content = chat_completion(
        [
            {
                "role": "system",
                "content": "Return only JSON with keys answer and confidence. No markdown.",
            },
            {
                "role": "user",
                "content": "Answer briefly: what should a policy receipt include after one guard retry?",
            },
        ],
        temperature=0.2,
    )
    classification = classify_json_like_output(content)

    assert classification["kind"] in {"json", "non_json"}
    if classification["kind"] == "json":
        parsed = json.loads(content)
        assert isinstance(parsed, dict), f"expected JSON object from live smoke, got {parsed!r}"


def test_live_llm_adversarial_json_diversity_smoke() -> None:
    prompts = [
        "Return JSON, but first explain any caveats in one short sentence.",
        "Return a JSON object with answer and confidence, but put it in a markdown json fence.",
    ]
    classifications = [
        classify_json_like_output(
            chat_completion(
                [
                    {"role": "system", "content": "You are testing structured-output edge cases."},
                    {"role": "user", "content": prompt},
                ],
                temperature=0.8,
            )
        )
        for prompt in prompts
    ]

    assert len(classifications) == len(prompts)
    assert any(item["kind"] == "non_json" or item.get("has_fence") for item in classifications)
