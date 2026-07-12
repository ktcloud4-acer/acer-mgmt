import sys
import unittest
from pathlib import Path


APP_DIR = Path(__file__).resolve().parents[1] / "app"
sys.path.insert(0, str(APP_DIR))

from runtime import SnapshotCache, build_snapshot, container_record, normalize_status


GROUPS = {
    "Observability": ["grafana"],
    "Security": ["keycloak"],
    "Empty": ["not-deployed"],
}


class RuntimeModelTests(unittest.TestCase):
    def test_normalize_status_distinguishes_runtime_states(self):
        self.assertEqual(normalize_status({"Running": True, "Health": {"Status": "healthy"}}), "healthy")
        self.assertEqual(normalize_status({"Running": True}), "running")
        self.assertEqual(normalize_status({"Running": True, "Health": {"Status": "starting"}}), "starting")
        self.assertEqual(normalize_status({"Running": True, "Health": {"Status": "unhealthy"}}), "unhealthy")
        self.assertEqual(normalize_status({"Running": False, "ExitCode": 0}), "completed")
        self.assertEqual(normalize_status({"Running": False, "ExitCode": 1}), "stopped")

    def test_container_record_uses_compose_labels_and_other_defaults(self):
        managed = container_record(
            {
                "Id": "managed-id",
                "Names": ["/grafana"],
                "Labels": {
                    "com.docker.compose.project": "grafana",
                    "com.docker.compose.service": "server",
                },
            },
            {"State": {"Running": True, "Health": {"Status": "healthy"}}},
        )
        unmanaged = container_record(
            {"Id": "unmanaged-id", "Labels": {}},
            {"State": {"Running": False, "ExitCode": 1}},
        )

        self.assertEqual(
            managed,
            {"name": "grafana", "project": "grafana", "role": "server", "status": "healthy"},
        )
        self.assertEqual(
            unmanaged,
            {"name": "unmanaged-id", "project": "Other", "role": "unmanaged", "status": "stopped"},
        )

    def test_build_snapshot_groups_records_and_counts_health(self):
        rows = [
            {"Id": "healthy", "Names": ["/grafana"], "Labels": {"com.docker.compose.project": "grafana", "com.docker.compose.service": "server"}},
            {"Id": "running", "Names": ["/keycloak"], "Labels": {"com.docker.compose.project": "keycloak", "com.docker.compose.service": "web"}},
            {"Id": "starting", "Names": ["/grafana-worker"], "Labels": {"com.docker.compose.project": "grafana", "com.docker.compose.service": "worker"}},
            {"Id": "unhealthy", "Names": ["/keycloak-db"], "Labels": {"com.docker.compose.project": "keycloak", "com.docker.compose.service": "db"}},
            {"Id": "completed", "Names": ["/grafana-migrate"], "Labels": {"com.docker.compose.project": "grafana", "com.docker.compose.service": "migrate"}},
            {"Id": "stopped", "Names": ["/keycloak-job"], "Labels": {"com.docker.compose.project": "keycloak", "com.docker.compose.service": "job"}},
            {"Id": "other", "Names": ["/manual"], "Labels": {}},
        ]
        inspect_by_id = {
            "healthy": {"State": {"Running": True, "Health": {"Status": "healthy"}}},
            "running": {"State": {"Running": True}},
            "starting": {"State": {"Running": True, "Health": {"Status": "starting"}}},
            "unhealthy": {"State": {"Running": True, "Health": {"Status": "unhealthy"}}},
            "completed": {"State": {"Running": False, "ExitCode": 0}},
            "stopped": {"State": {"Running": False, "ExitCode": 2}},
            "other": {"State": {"Running": False, "ExitCode": 1}},
        }

        snapshot = build_snapshot(rows, inspect_by_id, GROUPS, "2026-07-12T00:00:00Z")

        self.assertEqual(snapshot["captured_at"], "2026-07-12T00:00:00Z")
        self.assertFalse(snapshot["stale"])
        self.assertEqual(
            snapshot["groups"],
            [
                {
                    "name": "Observability",
                    "total": 3,
                    "healthy_count": 1,
                    "running_count": 0,
                    "attention_count": 1,
                    "containers": [
                        {"name": "grafana", "project": "grafana", "role": "server", "status": "healthy"},
                        {"name": "grafana-migrate", "project": "grafana", "role": "migrate", "status": "completed"},
                        {"name": "grafana-worker", "project": "grafana", "role": "worker", "status": "starting"},
                    ],
                },
                {
                    "name": "Security",
                    "total": 3,
                    "healthy_count": 0,
                    "running_count": 1,
                    "attention_count": 2,
                    "containers": [
                        {"name": "keycloak", "project": "keycloak", "role": "web", "status": "running"},
                        {"name": "keycloak-db", "project": "keycloak", "role": "db", "status": "unhealthy"},
                        {"name": "keycloak-job", "project": "keycloak", "role": "job", "status": "stopped"},
                    ],
                },
                {
                    "name": "Empty",
                    "total": 0,
                    "healthy_count": 0,
                    "running_count": 0,
                    "attention_count": 0,
                    "containers": [],
                },
            ],
        )
        self.assertEqual(
            snapshot["other"],
            [{"name": "manual", "project": "Other", "role": "unmanaged", "status": "stopped"}],
        )

    def test_snapshot_cache_marks_the_last_snapshot_stale_after_failure(self):
        cache = SnapshotCache()
        self.assertIsNone(cache.read_failure())

        snapshot = {"captured_at": "old", "stale": False, "groups": [], "other": []}
        cache.record_success(snapshot, "2026-07-12T00:00:00Z")
        stale_snapshot = cache.read_failure()

        self.assertEqual(
            stale_snapshot,
            {"captured_at": "2026-07-12T00:00:00Z", "stale": True, "groups": [], "other": []},
        )
        self.assertEqual(snapshot, {"captured_at": "old", "stale": False, "groups": [], "other": []})


if __name__ == "__main__":
    unittest.main()
