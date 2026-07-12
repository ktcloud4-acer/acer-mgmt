"""Pure data model for Docker runtime health snapshots."""

from copy import deepcopy


ATTENTION_STATUSES = {"starting", "unhealthy", "stopped"}


def normalize_status(state: dict) -> str:
    if state.get("Running"):
        health = state.get("Health", {}).get("Status")
        return health if health in {"healthy", "starting", "unhealthy"} else "running"
    return "completed" if state.get("ExitCode") == 0 else "stopped"


def container_record(summary: dict, inspect: dict) -> dict:
    labels = summary.get("Labels") or {}
    return {
        "name": (summary.get("Names") or [summary["Id"]])[0].lstrip("/"),
        "project": labels.get("com.docker.compose.project", "Other"),
        "role": labels.get("com.docker.compose.service", "unmanaged"),
        "status": normalize_status(inspect.get("State") or {}),
    }


def build_snapshot(rows, inspect_by_id, groups, captured_at) -> dict:
    group_records = {
        name: {
            "name": name,
            "total": 0,
            "healthy_count": 0,
            "running_count": 0,
            "attention_count": 0,
            "containers": [],
        }
        for name in groups
    }
    project_groups = {
        project: name
        for name, projects in groups.items()
        for project in projects
    }
    other = []

    for summary in rows:
        record = container_record(summary, inspect_by_id.get(summary["Id"], {}))
        group_name = project_groups.get(record["project"])
        if group_name is None:
            other.append(record)
            continue

        group = group_records[group_name]
        group["total"] += 1
        group["containers"].append(record)
        if record["status"] == "healthy":
            group["healthy_count"] += 1
        elif record["status"] == "running":
            group["running_count"] += 1
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
