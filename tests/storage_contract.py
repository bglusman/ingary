#!/usr/bin/env python3
"""Executable storage/sink contract fixture for Wardwright prototypes.

This is a reference harness, not the production storage layer. It makes the
storage-provider contract concrete against simple memory and JSON-file stores so
future SQLite, Postgres, search, and event-stream adapters have a shared oracle.
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import random
import string
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


CONTRACT_VERSION = "storage-contract-v0"
MIGRATION_VERSION = 1
FORBIDDEN_PAYLOAD_MARKERS = [
    "SECRET_PROMPT",
    "SECRET_COMPLETION",
    "sk-live-",
    "private-host.internal",
]


class ContractFailure(AssertionError):
    pass


class ImmutableVersionError(ValueError):
    pass


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise ContractFailure(message)


def clone(value: Any) -> Any:
    return copy.deepcopy(value)


def random_id(rng: random.Random, prefix: str, index: int) -> str:
    suffix = "".join(rng.choice(string.ascii_lowercase + string.digits) for _ in range(8))
    return f"{prefix}_{index}_{suffix}"


def sourced(value: str, source: str = "header") -> dict[str, str]:
    return {"value": value, "source": source}


def empty_state() -> dict[str, Any]:
    return {
        "migration_version": MIGRATION_VERSION,
        "providers": {},
        "concrete_models": {},
        "synthetic_models": {},
        "synthetic_model_versions": {},
        "rollouts": {},
        "receipts": {},
    }


@dataclass
class MemoryStore:
    durable: bool = False
    state: dict[str, Any] = field(default_factory=empty_state)

    def health(self) -> dict[str, Any]:
        return {
            "kind": "memory",
            "contract_version": CONTRACT_VERSION,
            "migration_version": self.state["migration_version"],
            "read_health": "ok",
            "write_health": "ok",
            "capabilities": {
                "durable": self.durable,
                "transactional": True,
                "concurrent_writers": False,
                "json_queries": True,
                "time_range_indexes": False,
                "retention_jobs": True,
            },
        }

    def create_provider(self, provider: dict[str, Any]) -> None:
        self.state["providers"][provider["id"]] = clone(provider)

    def create_concrete_model(self, model: dict[str, Any]) -> None:
        self.state["concrete_models"][model["id"]] = clone(model)

    def create_synthetic_model(self, model: dict[str, Any]) -> None:
        self.state["synthetic_models"][model["id"]] = clone(model)

    def create_model_version(self, version: dict[str, Any]) -> None:
        version = clone(version)
        version.setdefault("activated", False)
        self.state["synthetic_model_versions"][version["version_id"]] = version

    def update_model_version(self, version_id: str, patch: dict[str, Any]) -> None:
        current = self.state["synthetic_model_versions"][version_id]
        if current.get("activated"):
            raise ImmutableVersionError(f"activated model version {version_id} is immutable")
        current.update(clone(patch))

    def activate_version(self, synthetic_model_id: str, version_id: str, rollout: dict[str, Any]) -> None:
        version = self.state["synthetic_model_versions"][version_id]
        version["activated"] = True
        self.state["rollouts"][synthetic_model_id] = {
            "synthetic_model_id": synthetic_model_id,
            "active_version_id": version_id,
            **clone(rollout),
        }

    def rollback(self, synthetic_model_id: str, version_id: str) -> None:
        current = self.state["rollouts"].get(synthetic_model_id, {})
        self.state["rollouts"][synthetic_model_id] = {
            **current,
            "synthetic_model_id": synthetic_model_id,
            "active_version_id": version_id,
            "rollback": True,
        }

    def insert_receipt(self, receipt: dict[str, Any]) -> None:
        events = receipt.get("events", [])
        expect(bool(events), "receipt must include ordered events")
        expect(
            [event["sequence"] for event in events] == list(range(1, len(events) + 1)),
            "receipt events must be 1-based and contiguous",
        )
        self.state["receipts"][receipt["receipt_id"]] = clone(receipt)

    def get_receipt(self, receipt_id: str) -> dict[str, Any] | None:
        receipt = self.state["receipts"].get(receipt_id)
        return clone(receipt) if receipt is not None else None

    def list_receipts(self, filters: dict[str, Any] | None = None, limit: int = 50) -> list[dict[str, Any]]:
        filters = filters or {}
        receipts = [receipt for receipt in self.state["receipts"].values() if receipt_matches(receipt, filters)]
        receipts.sort(key=lambda item: (item["created_at"], item["receipt_id"]), reverse=True)
        return [receipt_summary(receipt) for receipt in receipts[:limit]]

    def apply_artifact_retention(self, created_before: int) -> None:
        for receipt in self.state["receipts"].values():
            if receipt["created_at"] < created_before:
                receipt["artifacts"] = []

    def receipt_events(self) -> list[dict[str, Any]]:
        events: list[dict[str, Any]] = []
        for receipt in self.state["receipts"].values():
            events.extend(clone(receipt.get("events", [])))
        events.sort(key=lambda event: (event["receipt_id"], event["sequence"]))
        return events

    def close(self) -> None:
        return None


@dataclass
class JsonFileStore(MemoryStore):
    path: Path = field(default_factory=Path)

    def __post_init__(self) -> None:
        self.durable = True
        if self.path.exists():
            self.state = json.loads(self.path.read_text(encoding="utf-8"))
        else:
            self.state = empty_state()
            self.flush()

    def health(self) -> dict[str, Any]:
        health = super().health()
        health["kind"] = "json-file"
        health["capabilities"]["durable"] = True
        return health

    def flush(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(self.path.suffix + ".tmp")
        tmp.write_text(json.dumps(self.state, indent=2, sort_keys=True), encoding="utf-8")
        os.replace(tmp, self.path)

    def create_provider(self, provider: dict[str, Any]) -> None:
        super().create_provider(provider)
        self.flush()

    def create_concrete_model(self, model: dict[str, Any]) -> None:
        super().create_concrete_model(model)
        self.flush()

    def create_synthetic_model(self, model: dict[str, Any]) -> None:
        super().create_synthetic_model(model)
        self.flush()

    def create_model_version(self, version: dict[str, Any]) -> None:
        super().create_model_version(version)
        self.flush()

    def update_model_version(self, version_id: str, patch: dict[str, Any]) -> None:
        super().update_model_version(version_id, patch)
        self.flush()

    def activate_version(self, synthetic_model_id: str, version_id: str, rollout: dict[str, Any]) -> None:
        super().activate_version(synthetic_model_id, version_id, rollout)
        self.flush()

    def rollback(self, synthetic_model_id: str, version_id: str) -> None:
        super().rollback(synthetic_model_id, version_id)
        self.flush()

    def insert_receipt(self, receipt: dict[str, Any]) -> None:
        super().insert_receipt(receipt)
        self.flush()

    def apply_artifact_retention(self, created_before: int) -> None:
        super().apply_artifact_retention(created_before)
        self.flush()


@dataclass
class EventStreamSink:
    ordered: bool = True
    seen_ids: set[str] = field(default_factory=set)
    events: list[dict[str, Any]] = field(default_factory=list)
    health: dict[str, Any] = field(default_factory=lambda: {"lag": 0, "queue_depth": 0})

    def publish(self, event: dict[str, Any]) -> None:
        event_id = event["event_id"]
        if event_id in self.seen_ids:
            return
        self.seen_ids.add(event_id)
        self.events.append(clone(event))

    def events_for_receipt(self, receipt_id: str) -> list[dict[str, Any]]:
        return [event for event in self.events if event["receipt_id"] == receipt_id]


@dataclass
class SearchSink:
    index: dict[str, dict[str, Any]] = field(default_factory=dict)
    health: dict[str, Any] = field(default_factory=lambda: {"stale": False, "last_checkpoint": None})

    def index_receipt(self, receipt: dict[str, Any]) -> None:
        self.index[receipt["receipt_id"]] = receipt_summary(receipt)
        self.health["last_checkpoint"] = receipt["receipt_id"]

    def search(self, filters: dict[str, Any] | None = None) -> list[dict[str, Any]]:
        filters = filters or {}
        rows = [row for row in self.index.values() if summary_matches(row, filters)]
        rows.sort(key=lambda item: (item["created_at"], item["receipt_id"]), reverse=True)
        return clone(rows)

    def mark_stale(self) -> None:
        self.index = {}
        self.health["stale"] = True

    def rebuild(self, receipts: list[dict[str, Any]]) -> None:
        self.index = {}
        for receipt in receipts:
            self.index_receipt(receipt)
        self.health["stale"] = False


@dataclass
class LogSink:
    payloads: list[dict[str, Any]] = field(default_factory=list)
    health: dict[str, Any] = field(default_factory=lambda: {"queue_depth": 0, "dropped": 0})

    def publish_receipt(self, receipt: dict[str, Any]) -> None:
        self.payloads.append(
            {
                "receipt_id": receipt["receipt_id"],
                "synthetic_model": receipt["synthetic_model"],
                "synthetic_version": receipt["synthetic_version"],
                "caller": clone(receipt["caller"]),
                "decision": {
                    "selected_provider": receipt["decision"]["selected_provider"],
                    "selected_model": receipt["decision"]["selected_model"],
                    "status": receipt["final"]["status"],
                },
            }
        )


def receipt_summary(receipt: dict[str, Any]) -> dict[str, Any]:
    return {
        "receipt_id": receipt["receipt_id"],
        "created_at": receipt["created_at"],
        "receipt_schema": receipt["receipt_schema"],
        "synthetic_model": receipt["synthetic_model"],
        "synthetic_version": receipt["synthetic_version"],
        "tenant_id": receipt["caller"]["tenant_id"]["value"],
        "application_id": receipt["caller"]["application_id"]["value"],
        "consuming_agent_id": receipt["caller"]["consuming_agent_id"]["value"],
        "consuming_user_id": receipt["caller"]["consuming_user_id"]["value"],
        "session_id": receipt["caller"]["session_id"]["value"],
        "run_id": receipt["caller"]["run_id"]["value"],
        "selected_provider": receipt["decision"]["selected_provider"],
        "selected_model": receipt["decision"]["selected_model"],
        "status": receipt["final"]["status"],
        "simulation": receipt["simulation"],
        "stream_policy_action": receipt["final"].get("stream_policy_action"),
    }


def receipt_matches(receipt: dict[str, Any], filters: dict[str, Any]) -> bool:
    return summary_matches(receipt_summary(receipt), filters)


def summary_matches(summary: dict[str, Any], filters: dict[str, Any]) -> bool:
    for key, value in filters.items():
        if key == "created_at_min":
            if summary["created_at"] < value:
                return False
        elif key == "created_at_max":
            if summary["created_at"] > value:
                return False
        elif value is not None and summary.get(key) != value:
            return False
    return True


def generated_receipt(rng: random.Random, index: int, created_at: int | None = None) -> dict[str, Any]:
    receipt_id = random_id(rng, "rcpt", index)
    model = rng.choice(["coding-balanced", "json-extractor", "premium-review"])
    version = f"{model}-v{rng.randint(1, 4)}"
    provider = rng.choice(["local", "managed", "premium"])
    concrete = f"{provider}/{rng.choice(['small', 'balanced', 'large'])}"
    status = rng.choice(["success", "simulated", "blocked", "retry_success"])
    simulation = status == "simulated"
    stream_action = rng.choice([None, "pass", "inject_reminder_and_retry", "block_final"])
    created = created_at if created_at is not None else 1_800_000_000 + index
    caller = {
        "tenant_id": sourced(f"tenant-{rng.randint(1, 3)}"),
        "application_id": sourced(f"app-{rng.randint(1, 3)}"),
        "consuming_agent_id": sourced(f"agent-{rng.randint(1, 5)}"),
        "consuming_user_id": sourced(f"user-{rng.randint(1, 8)}"),
        "session_id": sourced(f"session-{rng.randint(1, 4)}"),
        "run_id": sourced(f"run-{index}"),
    }
    events = [
        {
            "event_id": f"{receipt_id}:1",
            "receipt_id": receipt_id,
            "sequence": 1,
            "type": "route_planned",
            "selected_model": concrete,
        },
        {
            "event_id": f"{receipt_id}:2",
            "receipt_id": receipt_id,
            "sequence": 2,
            "type": "provider_attempt",
            "provider": provider,
            "model": concrete,
        },
        {
            "event_id": f"{receipt_id}:3",
            "receipt_id": receipt_id,
            "sequence": 3,
            "type": "finalized",
            "status": status,
        },
    ]
    return {
        "receipt_schema": "v1",
        "receipt_id": receipt_id,
        "created_at": created,
        "synthetic_model": model,
        "synthetic_version": version,
        "caller": caller,
        "simulation": simulation,
        "request": {
            "estimated_prompt_tokens": rng.randint(1, 100_000),
            "content_captured": False,
        },
        "decision": {
            "selected_provider": provider,
            "selected_model": concrete,
            "skipped": [{"target": "cheap/tiny", "reason": "context_window_too_small"}],
        },
        "attempts": [
            {
                "provider": provider,
                "model": concrete,
                "status": status,
                "called_provider": not simulation,
            }
        ],
        "events": events,
        "artifacts": [
            {
                "kind": "redacted_prompt",
                "value": "[REDACTED]",
                "original_marker_for_test": "SECRET_PROMPT",
            }
        ],
        "final": {
            "status": status,
            "latency_ms": rng.randint(2, 5000),
            "stream_policy_action": stream_action,
            "cost_usd": round(rng.random() / 10, 5),
        },
    }


def seed_control_plane(store: MemoryStore) -> tuple[str, str, str]:
    store.create_provider({"id": "local", "kind": "openai-compatible", "health": "ok"})
    store.create_concrete_model({"id": "local/small", "provider": "local", "context_window": 32768})
    store.create_synthetic_model({"id": "coding-balanced", "namespace": "flat"})
    v1 = "coding-balanced-v1"
    v2 = "coding-balanced-v2"
    store.create_model_version({"version_id": v1, "synthetic_model_id": "coding-balanced", "route_graph": {"root": "local/small"}})
    store.create_model_version({"version_id": v2, "synthetic_model_id": "coding-balanced", "route_graph": {"root": "local/small"}})
    store.activate_version("coding-balanced", v1, {"mode": "active"})
    return "coding-balanced", v1, v2


def assert_control_plane_contract(store: MemoryStore) -> None:
    model_id, v1, v2 = seed_control_plane(store)
    try:
        store.update_model_version(v1, {"route_graph": {"root": "managed/large"}})
        raise ContractFailure("activated model version was mutable")
    except ImmutableVersionError:
        pass
    before = clone(store.state["synthetic_model_versions"][v1])
    store.rollback(model_id, v2)
    after = store.state["synthetic_model_versions"][v1]
    expect(before == after, "rollback mutated activated version history")
    expect(store.state["rollouts"][model_id]["active_version_id"] == v2, "rollback did not update active pointer")


def assert_receipt_contract(store: MemoryStore, rng: random.Random, cases: int) -> list[dict[str, Any]]:
    receipts = [generated_receipt(rng, i, created_at=1_800_000_000 + (i // 2)) for i in range(cases)]
    for receipt in receipts:
        store.insert_receipt(receipt)
        fetched = store.get_receipt(receipt["receipt_id"])
        expect(fetched == receipt, "receipt round-trip changed payload")

    expected_order = sorted(receipts, key=lambda item: (item["created_at"], item["receipt_id"]), reverse=True)
    listed = store.list_receipts(limit=cases)
    expect([row["receipt_id"] for row in listed] == [row["receipt_id"] for row in expected_order], "receipt ordering mismatch")

    sample = receipts[cases // 2]
    filters = {
        "tenant_id": sample["caller"]["tenant_id"]["value"],
        "consuming_agent_id": sample["caller"]["consuming_agent_id"]["value"],
        "synthetic_model": sample["synthetic_model"],
        "status": sample["final"]["status"],
    }
    expected = [receipt_summary(item) for item in expected_order if receipt_matches(item, filters)]
    actual = store.list_receipts(filters=filters, limit=cases)
    expect(actual == expected, "filtered receipt summaries differed from oracle")

    sim_expected = [receipt_summary(item) for item in expected_order if item["simulation"]]
    sim_actual = store.list_receipts(filters={"simulation": True}, limit=cases)
    expect(sim_actual == sim_expected, "simulation filter differed from oracle")

    old = min(receipt["created_at"] for receipt in receipts) + 1
    store.apply_artifact_retention(created_before=old)
    for receipt in receipts:
        persisted = store.get_receipt(receipt["receipt_id"])
        expect(persisted is not None, "retention deleted receipt metadata")
        if receipt["created_at"] < old:
            expect(persisted["artifacts"] == [], "retention did not delete old artifacts")
        else:
            expect(persisted["artifacts"], "retention deleted unexpired artifacts")

    return [store.get_receipt(receipt["receipt_id"]) for receipt in receipts if store.get_receipt(receipt["receipt_id"]) is not None]


def assert_sink_contract(receipts: list[dict[str, Any]]) -> None:
    event_sink = EventStreamSink()
    search_sink = SearchSink()
    log_sink = LogSink()

    for receipt in receipts:
        for event in receipt["events"]:
            event_sink.publish(event)
            event_sink.publish(event)
        search_sink.index_receipt(receipt)
        search_sink.index_receipt(receipt)
        log_sink.publish_receipt(receipt)

    for receipt in receipts:
        actual_events = event_sink.events_for_receipt(receipt["receipt_id"])
        expect(
            [event["event_id"] for event in actual_events] == [event["event_id"] for event in receipt["events"]],
            "event sink did not preserve per-receipt event IDs/order/idempotency",
        )

    sample = receipt_summary(receipts[len(receipts) // 2])
    filters = {
        "consuming_user_id": sample["consuming_user_id"],
        "synthetic_model": sample["synthetic_model"],
        "status": sample["status"],
    }
    expected_search = [
        receipt_summary(receipt)
        for receipt in sorted(receipts, key=lambda item: (item["created_at"], item["receipt_id"]), reverse=True)
        if summary_matches(receipt_summary(receipt), filters)
    ]
    expect(search_sink.search(filters) == expected_search, "search sink projection differed from oracle")

    payload_text = json.dumps(log_sink.payloads, sort_keys=True)
    for marker in FORBIDDEN_PAYLOAD_MARKERS:
        expect(marker not in payload_text, f"log sink leaked forbidden marker {marker}")

    search_sink.mark_stale()
    expect(search_sink.health["stale"], "search sink did not report stale state")
    search_sink.rebuild(receipts)
    expect(not search_sink.health["stale"], "search sink stayed stale after rebuild")
    expect(search_sink.search({}) == SearchSink(index={r["receipt_id"]: receipt_summary(r) for r in receipts}).search({}), "rebuild projection mismatch")


def open_store(kind: str, path: Path | None) -> MemoryStore:
    if kind == "memory":
        return MemoryStore()
    if kind == "json-file":
        if path is None:
            raise ValueError("--path is required for json-file store")
        return JsonFileStore(path=path)
    raise ValueError(f"unknown store kind {kind}")


def run_contract(kind: str, path: Path | None, cases: int, seed: int) -> None:
    rng = random.Random(seed)
    store = open_store(kind, path)
    health = store.health()
    expect(health["contract_version"] == CONTRACT_VERSION, "contract version mismatch")
    expect(health["migration_version"] == MIGRATION_VERSION, "migration version mismatch")
    assert_control_plane_contract(store)
    receipts = assert_receipt_contract(store, rng, cases)
    assert_sink_contract(receipts)

    if health["capabilities"].get("durable"):
        store.close()
        reopened = open_store(kind, path)
        expect(len(reopened.list_receipts(limit=cases)) == cases, "durable store lost receipts after reopen")

    print(f"storage contract passed store={kind} cases={cases} seed={seed}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--store", choices=["memory", "json-file", "all"], default="all")
    parser.add_argument("--path", type=Path, default=None, help="Path for json-file store.")
    parser.add_argument("--cases", type=int, default=50)
    parser.add_argument("--seed", type=int, default=20260513)
    args = parser.parse_args()

    if args.store == "all":
        run_contract("memory", None, args.cases, args.seed)
        with tempfile.TemporaryDirectory(prefix="wardwright-storage-contract-") as tempdir:
            run_contract("json-file", Path(tempdir) / "store.json", args.cases, args.seed)
    else:
        run_contract(args.store, args.path, args.cases, args.seed)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ContractFailure as exc:
        print(f"storage contract failure: {exc}")
        raise SystemExit(1)
