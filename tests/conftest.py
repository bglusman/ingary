from __future__ import annotations

import os

import pytest


def pytest_addoption(parser: pytest.Parser) -> None:
    parser.addoption(
        "--base-url",
        default=os.environ.get("INGARY_TEST_BASE_URL", "http://127.0.0.1:8787"),
        help="Base URL for backend contract tests.",
    )
    parser.addoption(
        "--backend-timeout",
        type=float,
        default=float(os.environ.get("INGARY_TEST_TIMEOUT", "10")),
        help="Per-request timeout for backend contract tests.",
    )


@pytest.fixture
def base_url(request: pytest.FixtureRequest) -> str:
    return str(request.config.getoption("--base-url"))


@pytest.fixture
def backend_timeout(request: pytest.FixtureRequest) -> float:
    return float(request.config.getoption("--backend-timeout"))
