#!/usr/bin/env python3
"""Run a tiny instrumented bakeoff probe from a static action plan.

This is not the real bakeoff runner. It is a calibration harness for deciding
what we can reliably measure before sending agents into comparable feature
implementation branches.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


TOKEN_PATTERN = re.compile(r"\w+|[^\w\s]", re.UNICODE)


@dataclass(frozen=True)
class TokenEstimate:
    tokens: int
    method: str


def estimate_tokens(text: str) -> TokenEstimate:
    try:
        import tiktoken  # type: ignore

        encoding = tiktoken.get_encoding("cl100k_base")
        return TokenEstimate(tokens=len(encoding.encode(text)), method="tiktoken:cl100k_base")
    except Exception:
        # This intentionally overcounts punctuation-heavy code a little and
        # undercounts very long identifiers a little. It is stable and cheap,
        # which is enough for harness calibration when real provider usage is
        # unavailable.
        return TokenEstimate(tokens=len(TOKEN_PATTERN.findall(text)), method="regex_words_punct")


def run_git(args: list[str], cwd: Path) -> str:
    try:
        completed = subprocess.run(
            ["git", *args],
            cwd=cwd,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError:
        return ""
    return completed.stdout.strip()


def parse_numstat(numstat: str) -> dict[str, int]:
    files_changed = 0
    lines_added = 0
    lines_deleted = 0
    for line in numstat.splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        files_changed += 1
        if parts[0].isdigit():
            lines_added += int(parts[0])
        if parts[1].isdigit():
            lines_deleted += int(parts[1])
    return {
        "files_changed": files_changed,
        "lines_added": lines_added,
        "lines_deleted": lines_deleted,
    }


def extract_jsonl_usage(text: str) -> dict[str, int] | None:
    totals: dict[str, int] = {}
    found = False
    for line in text.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        usage = event.get("usage") if isinstance(event, dict) else None
        if not isinstance(usage, dict):
            continue
        found = True
        for key, value in usage.items():
            if isinstance(value, int):
                totals[key] = totals.get(key, 0) + value
    return totals if found else None


def derive_model_usage(usage: dict[str, int]) -> dict[str, float | int]:
    input_tokens = usage.get("input_tokens", 0)
    cached_input_tokens = usage.get("cached_input_tokens", 0)
    output_tokens = usage.get("output_tokens", 0)
    uncached_input_tokens = max(0, input_tokens - cached_input_tokens)
    cache_hit_rate = cached_input_tokens / input_tokens if input_tokens else 0.0
    return {
        "input_tokens": input_tokens,
        "cached_input_tokens": cached_input_tokens,
        "uncached_input_tokens": uncached_input_tokens,
        "cache_hit_rate": round(cache_hit_rate, 6),
        "output_tokens": output_tokens,
        "reasoning_output_tokens": usage.get("reasoning_output_tokens", 0),
        "weighted_total_input_plus_5x_output": input_tokens + (5 * output_tokens),
        "weighted_uncached_input_plus_5x_output": uncached_input_tokens + (5 * output_tokens),
    }


def git_snapshot(cwd: Path) -> dict[str, Any]:
    status = run_git(["status", "--short"], cwd)
    head = run_git(["rev-parse", "HEAD"], cwd)
    branch = run_git(["branch", "--show-current"], cwd)
    shortstat = run_git(["diff", "--shortstat", "HEAD"], cwd)
    numstat = run_git(["diff", "--numstat", "HEAD"], cwd)
    stats = parse_numstat(numstat)
    status_lines = status.splitlines()
    return {
        "head": head,
        "branch": branch,
        "status": status_lines,
        "status_count": len(status_lines),
        "modified_count": sum(1 for line in status_lines if line.startswith(" M") or line.startswith("M ")),
        "untracked_count": sum(1 for line in status_lines if line.startswith("??")),
        "shortstat": shortstat,
        **stats,
    }


def git_commit_delta(cwd: Path, before: str, after: str) -> dict[str, Any]:
    if not before or not after:
        return {
            "head_changed": False,
            "commits_added": 0,
            "shortstat": "",
            "files_changed": 0,
            "lines_added": 0,
            "lines_deleted": 0,
            "commits": [],
        }
    if before == after:
        return {
            "head_changed": False,
            "commits_added": 0,
            "shortstat": "",
            "files_changed": 0,
            "lines_added": 0,
            "lines_deleted": 0,
            "commits": [],
        }
    numstat = run_git(["diff", "--numstat", before, after], cwd)
    commits_added_raw = run_git(["rev-list", "--count", f"{before}..{after}"], cwd)
    try:
        commits_added = int(commits_added_raw)
    except ValueError:
        commits_added = 0
    return {
        "head_changed": True,
        "commits_added": commits_added,
        "shortstat": run_git(["diff", "--shortstat", before, after], cwd),
        **parse_numstat(numstat),
        "commits": run_git(["log", "--oneline", "--no-decorate", f"{before}..{after}"], cwd).splitlines(),
    }


def action_text(action: dict[str, Any]) -> str:
    return json.dumps(action, sort_keys=True, separators=(",", ":"))


def write_artifact(artifact_dir: Path | None, name: str, content: str) -> str | None:
    if artifact_dir is None:
        return None
    artifact_dir.mkdir(parents=True, exist_ok=True)
    path = artifact_dir / name
    path.write_text(content)
    return str(path)


def run_action(action: dict[str, Any], cwd: Path, timeout: float, artifact_dir: Path | None) -> dict[str, Any]:
    started = time.perf_counter()
    kind = action.get("kind")
    action_id = str(action.get("id", "action")).replace("/", "_")
    if kind == "note":
        output = str(action.get("output", ""))
        tokens = estimate_tokens(output)
        stdout_path = write_artifact(artifact_dir, f"{action_id}.stdout.txt", output)
        return {
            "id": action.get("id"),
            "kind": kind,
            "ok": True,
            "duration_ms": round((time.perf_counter() - started) * 1000, 3),
            "stdout_preview": output[:4000],
            "stderr_preview": "",
            "stdout_bytes": len(output.encode("utf-8")),
            "stderr_bytes": 0,
            "stdout_path": stdout_path,
            "stderr_path": None,
            "estimated_output_tokens": tokens.tokens,
            "tokenizer": tokens.method,
        }
    if kind != "command":
        return {
            "id": action.get("id"),
            "kind": kind,
            "ok": False,
            "duration_ms": round((time.perf_counter() - started) * 1000, 3),
            "error": f"unsupported action kind {kind!r}",
        }

    cmd = action.get("cmd")
    if not isinstance(cmd, list) or not all(isinstance(part, str) for part in cmd):
        return {
            "id": action.get("id"),
            "kind": kind,
            "ok": False,
            "duration_ms": round((time.perf_counter() - started) * 1000, 3),
            "error": "command actions require cmd as a list of strings",
        }

    try:
        completed = subprocess.run(
            cmd,
            cwd=cwd,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
            timeout=timeout,
            env={**os.environ, **{str(k): str(v) for k, v in action.get("env", {}).items()}},
        )
        stdout = completed.stdout
        stderr = completed.stderr
        tokens = estimate_tokens(stdout + "\n" + stderr)
        model_usage = extract_jsonl_usage(stdout)
        stdout_path = write_artifact(artifact_dir, f"{action_id}.stdout.txt", stdout)
        stderr_path = write_artifact(artifact_dir, f"{action_id}.stderr.txt", stderr)
        return {
            "id": action.get("id"),
            "kind": kind,
            "cmd": cmd,
            "ok": completed.returncode == 0,
            "returncode": completed.returncode,
            "duration_ms": round((time.perf_counter() - started) * 1000, 3),
            "stdout_preview": stdout[:4000],
            "stderr_preview": stderr[:4000],
            "stdout_bytes": len(stdout.encode("utf-8")),
            "stderr_bytes": len(stderr.encode("utf-8")),
            "stdout_path": stdout_path,
            "stderr_path": stderr_path,
            "estimated_output_tokens": tokens.tokens,
            "model_usage": model_usage,
            "tokenizer": tokens.method,
        }
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode("utf-8", errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode("utf-8", errors="replace")
        stdout_path = write_artifact(artifact_dir, f"{action_id}.stdout.txt", stdout)
        stderr_path = write_artifact(artifact_dir, f"{action_id}.stderr.txt", stderr)
        return {
            "id": action.get("id"),
            "kind": kind,
            "cmd": cmd,
            "ok": False,
            "timed_out": True,
            "duration_ms": round((time.perf_counter() - started) * 1000, 3),
            "stdout_preview": stdout[:4000],
            "stderr_preview": stderr[:4000],
            "stdout_path": stdout_path,
            "stderr_path": stderr_path,
        }


def compare_expected(expected: dict[str, Any], observed: dict[str, Any]) -> list[dict[str, Any]]:
    comparisons: list[dict[str, Any]] = []
    for key, want in expected.items():
        got = observed.get(key)
        comparisons.append({"metric": key, "expected": want, "observed": got, "matched": got == want})
    return comparisons


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan", type=Path)
    parser.add_argument("--cwd", type=Path, default=Path.cwd())
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--artifact-dir", type=Path, default=None)
    parser.add_argument("--timeout", type=float, default=10.0)
    args = parser.parse_args()

    plan = json.loads(args.plan.read_text())
    cwd = args.cwd.resolve()
    actions = plan.get("actions", [])
    if not isinstance(actions, list):
        raise SystemExit("plan actions must be a list")

    started_wall = time.time()
    started = time.perf_counter()
    git_before = git_snapshot(cwd)
    input_blob = json.dumps(
        {
            "run_id": plan.get("run_id"),
            "feature": plan.get("feature"),
            "backend": plan.get("backend"),
            "prompt": plan.get("simulated_prompt", ""),
            "actions": [action_text(action) for action in actions],
        },
        sort_keys=True,
    )
    input_tokens = estimate_tokens(input_blob)
    write_artifact(args.artifact_dir, "input_blob.json", input_blob)
    action_results = [run_action(action, cwd, args.timeout, args.artifact_dir) for action in actions]
    git_after = git_snapshot(cwd)
    git_delta = git_commit_delta(cwd, str(git_before.get("head", "")), str(git_after.get("head", "")))
    elapsed_ms = round((time.perf_counter() - started) * 1000, 3)

    command_count = sum(1 for result in action_results if result.get("kind") == "command")
    command_duration_ms = round(
        sum(float(result.get("duration_ms", 0)) for result in action_results if result.get("kind") == "command"),
        3,
    )
    output_tokens = sum(int(result.get("estimated_output_tokens", 0)) for result in action_results)
    model_usage: dict[str, int] = {}
    for result in action_results:
        usage = result.get("model_usage")
        if not isinstance(usage, dict):
            continue
        for key, value in usage.items():
            if isinstance(value, int):
                model_usage[key] = model_usage.get(key, 0) + value
    stdout_bytes = sum(int(result.get("stdout_bytes", 0)) for result in action_results)
    stderr_bytes = sum(int(result.get("stderr_bytes", 0)) for result in action_results)
    observed = {
        "commands": command_count,
        "actions": len(action_results),
        "failed_actions": sum(1 for result in action_results if not result.get("ok")),
        "git_files_changed_before": git_before["files_changed"],
        "git_files_changed_after": git_after["files_changed"],
        "git_status_changed": git_before["status"] != git_after["status"],
        "git_head_changed": git_delta["head_changed"],
        "git_commits_added": git_delta["commits_added"],
        "git_files_changed_in_commits": git_delta["files_changed"],
        "git_untracked_after": git_after["untracked_count"],
    }
    result = {
        "schema": "wardwright.bakeoff_harness.v0",
        "run_id": plan.get("run_id"),
        "feature": plan.get("feature"),
        "backend": plan.get("backend"),
        "started_at_unix": started_wall,
        "duration_ms": elapsed_ms,
        "token_estimate": {
            "input_tokens": input_tokens.tokens,
            "output_tokens": output_tokens,
            "weighted_tokens_input_plus_5x_output": input_tokens.tokens + (5 * output_tokens),
            "method": input_tokens.method,
        },
        "model_usage": model_usage or None,
        "model_usage_derived": derive_model_usage(model_usage) if model_usage else None,
        "command_count": command_count,
        "command_duration_ms": command_duration_ms,
        "action_count": len(action_results),
        "stdout_bytes": stdout_bytes,
        "stderr_bytes": stderr_bytes,
        "git_before": git_before,
        "git_after": git_after,
        "git_delta": git_delta,
        "actions": action_results,
        "expected_comparisons": compare_expected(plan.get("expected", {}), observed),
    }

    payload = json.dumps(result, indent=2, sort_keys=True)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload + "\n")
    print(payload)
    return 1 if any(not action.get("ok") for action in action_results) else 0


if __name__ == "__main__":
    raise SystemExit(main())
