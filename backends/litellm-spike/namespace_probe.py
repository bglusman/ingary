#!/usr/bin/env python3
"""Demonstrate Ingary model namespace handling without LiteLLM dependencies."""

from __future__ import annotations

import json
import sys
from dataclasses import asdict, dataclass


PUBLIC_SYNTHETIC_MODELS = {
    "coding-balanced": {
        "flat": "coding-balanced",
        "prefixed": "ingary/coding-balanced",
        "route_version": "2026-05-13.litellm-spike",
        "targets": ["local/qwen-coder", "managed/kimi-k2.6"],
    }
}


@dataclass(frozen=True)
class NamespaceResult:
    input_model: str
    accepted: bool
    namespace_mode: str | None
    synthetic_model: str | None
    public_model_id: str | None
    reason: str


def normalize_model(model: str) -> NamespaceResult:
    if model in PUBLIC_SYNTHETIC_MODELS:
        return NamespaceResult(
            input_model=model,
            accepted=True,
            namespace_mode="flat",
            synthetic_model=model,
            public_model_id=model,
            reason="flat synthetic model ID",
        )

    prefix = "ingary/"
    if model.startswith(prefix):
        synthetic = model.removeprefix(prefix)
        if synthetic in PUBLIC_SYNTHETIC_MODELS:
            return NamespaceResult(
                input_model=model,
                accepted=True,
                namespace_mode="prefixed",
                synthetic_model=synthetic,
                public_model_id=model,
                reason="prefixed synthetic model ID",
            )

        return NamespaceResult(
            input_model=model,
            accepted=False,
            namespace_mode="prefixed",
            synthetic_model=synthetic,
            public_model_id=None,
            reason="unknown Ingary synthetic model",
        )

    return NamespaceResult(
        input_model=model,
        accepted=False,
        namespace_mode=None,
        synthetic_model=None,
        public_model_id=None,
        reason="outside Ingary namespace; leave to LiteLLM/provider catalog",
    )


def main(argv: list[str]) -> int:
    models = argv or [
        "coding-balanced",
        "ingary/coding-balanced",
        "ingary/unknown",
        "openai/gpt-example",
    ]
    print(json.dumps([asdict(normalize_model(model)) for model in models], indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
