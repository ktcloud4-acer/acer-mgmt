"""Pure data model for Docker runtime health snapshots."""

from copy import deepcopy


ATTENTION_STATUSES = {"starting", "unhealthy", "failed"}


def normalize_status(state: dict) -> str:
    if state.get("Running"):
        health = state.get("Health", {}).get("Status")
        return health if health in {"healthy", "starting", "unhealthy"} else "unchecked"
    return "completed" if state.get("ExitCode") == 0 else "failed"


def container_record(summary: dict, inspect: dict) -> dict:
    labels = summary.get("Labels") or {}
    return {
        "name": (summary.get("Names") or [summary["Id"]])[0].lstrip("/"),
        "project": labels.get("com.docker.compose.project", "Other"),
        "role": labels.get("com.docker.compose.service", "unmanaged"),
        "status": normalize_status(inspect.get("State") or {}),
    }


def normalize_group_rules(groups: dict) -> dict:
    """Accept legacy project lists and explicit project/name/prefix rules."""
    normalized = {}
    for group_name, rule in groups.items():
        if isinstance(rule, list):
            rule = {"projects": rule}
        normalized[group_name] = {
            "projects": set(rule.get("projects", [])),
            "names": set(rule.get("names", [])),
            "prefixes": tuple(rule.get("prefixes", [])),
        }
    return normalized


def group_for_record(record: dict, rules: dict) -> str | None:
    for group_name, rule in rules.items():
        if record["project"] in rule["projects"]:
            return group_name
        if record["name"] in rule["names"]:
            return group_name
        if any(record["name"].startswith(prefix) for prefix in rule["prefixes"]):
            return group_name
    return None


def build_snapshot(rows, inspect_by_id, groups, captured_at) -> dict:
    group_records = {
        name: {
            "name": name,
            "total": 0,
            "healthy_count": 0,
            "unchecked_count": 0,
            "completed_count": 0,
            "attention_count": 0,
            "containers": [],
        }
        for name in groups
    }
    rules = normalize_group_rules(groups)
    other = []

    for summary in rows:
        record = container_record(summary, inspect_by_id.get(summary["Id"], {}))
        group_name = group_for_record(record, rules)
        if group_name is None:
            other.append(record)
            continue

        group = group_records[group_name]
        group["total"] += 1
        group["containers"].append(record)
        if record["status"] == "healthy":
            group["healthy_count"] += 1
        elif record["status"] == "unchecked":
            group["unchecked_count"] += 1
        elif record["status"] == "completed":
            group["completed_count"] += 1
        elif record["status"] in ATTENTION_STATUSES:
            group["attention_count"] += 1

    for group in group_records.values():
        group["containers"].sort(key=lambda record: record["name"])
    other.sort(key=lambda record: record["name"])

    return {
        "captured_at": captured_at,
        "stale": False,
        "groups": list(group_records.values()),
        "other": other,
    }


class SnapshotCache:
    def __init__(self):
        self._snapshot = None

    def record_success(self, snapshot, captured_at):
        self._snapshot = deepcopy(snapshot)
        self._snapshot["captured_at"] = captured_at
        self._snapshot["stale"] = False

    def read_failure(self):
        if self._snapshot is None:
            return None
        stale_snapshot = deepcopy(self._snapshot)
        stale_snapshot["stale"] = True
        return stale_snapshot
