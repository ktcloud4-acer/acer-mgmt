import sys
import unittest
import importlib.util
import json
import threading
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch


APP_DIR = Path(__file__).resolve().parents[1] / "app"
sys.path.insert(0, str(APP_DIR))

from runtime import SnapshotCache, build_snapshot, container_record, normalize_status


SERVER_SPEC = importlib.util.find_spec("server")
if SERVER_SPEC:
    from server import DockerClient, DockerUnavailable, RuntimeHTTPServer, RuntimeService, resolve_static_path


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


class FakeDockerClient:
    def __init__(self, rows, inspections, list_error=None, inspect_error=None):
        self.rows = rows
        self.inspections = inspections
        self.list_error = list_error
        self.inspect_error = inspect_error
        self.list_calls = 0
        self.inspect_calls = []

    def list_containers(self):
        self.list_calls += 1
        if self.list_error:
            raise self.list_error
        return self.rows

    def inspect_container(self, container_id):
        self.inspect_calls.append(container_id)
        if self.inspect_error:
            raise self.inspect_error
        return self.inspections[container_id]


class ServerModuleTests(unittest.TestCase):
    def test_server_module_exists(self):
        self.assertIsNotNone(SERVER_SPEC)


@unittest.skipUnless(SERVER_SPEC, "server module has not been implemented yet")
class RuntimeServiceTests(unittest.TestCase):
    def setUp(self):
        self.rows = [
            {
                "Id": "grafana/id",
                "Names": ["/grafana"],
                "Labels": {
                    "com.docker.compose.project": "grafana",
                    "com.docker.compose.service": "server",
                    "private": "do-not-expose",
                },
            },
            {
                "Id": "manual-id",
                "Names": ["/manual"],
                "Labels": {"private": "do-not-expose"},
            },
        ]
        self.inspections = {
            "grafana/id": {
                "State": {"Running": True, "Health": {"Status": "healthy"}},
                "Config": {"Env": ["SECRET=value"], "Image": "private/image"},
                "Mounts": [{"Source": "/secret"}],
                "NetworkSettings": {"Networks": {}},
            },
            "manual-id": {"State": {"Running": True}},
        }
        self.now = lambda: datetime(2026, 7, 12, tzinfo=timezone.utc)

    def test_refresh_lists_once_inspects_each_container_and_minimizes_the_snapshot(self):
        client = FakeDockerClient(self.rows, self.inspections)
        service = RuntimeService(client, SnapshotCache(), GROUPS, now=self.now)

        snapshot = service.refresh()

        self.assertEqual(client.list_calls, 1)
        self.assertEqual(client.inspect_calls, ["grafana/id", "manual-id"])
        self.assertEqual(snapshot["groups"][0]["containers"], [{"name": "grafana", "project": "grafana", "role": "server", "status": "healthy"}])
        self.assertEqual(snapshot["other"], [{"name": "manual", "project": "Other", "role": "unmanaged", "status": "running"}])
        self.assertNotIn("Env", repr(snapshot))
        self.assertNotIn("Mounts", repr(snapshot))
        self.assertNotIn("Image", repr(snapshot))
        self.assertNotIn("NetworkSettings", repr(snapshot))
        self.assertNotIn("private", repr(snapshot))

    def test_runtime_data_raises_unavailable_when_an_upstream_error_has_no_cached_snapshot(self):
        service = RuntimeService(FakeDockerClient([], {}, list_error=OSError("offline")), SnapshotCache(), GROUPS, now=self.now)

        with self.assertRaises(DockerUnavailable):
            service.runtime_data()

    def test_runtime_data_returns_a_stale_cached_snapshot_after_an_upstream_error(self):
        cache = SnapshotCache()
        service = RuntimeService(FakeDockerClient(self.rows, self.inspections), cache, GROUPS, now=self.now)
        service.refresh()
        service.client = FakeDockerClient([], {}, list_error=OSError("offline"))

        snapshot = service.runtime_data()

        self.assertTrue(snapshot["stale"])
        self.assertEqual(snapshot["captured_at"], "2026-07-12T00:00:00Z")

    def test_refresh_does_not_replace_a_cached_snapshot_when_an_inspection_fails(self):
        cache = SnapshotCache()
        cache.record_success({"captured_at": "old", "stale": False, "groups": [], "other": []}, "old")
        service = RuntimeService(
            FakeDockerClient(self.rows, self.inspections, inspect_error=OSError("offline")),
            cache,
            GROUPS,
            now=self.now,
        )

        with self.assertRaises(OSError):
            service.refresh()

        self.assertEqual(cache.read_failure()["captured_at"], "old")


@unittest.skipUnless(SERVER_SPEC, "server module has not been implemented yet")
class DockerClientTests(unittest.TestCase):
    def test_docker_client_uses_only_internal_allowlisted_get_paths(self):
        requested = []

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self):
                return b'[{"Id": "one"}]'

        def fake_urlopen(request, timeout):
            requested.append((request.full_url, request.get_method(), timeout))
            return Response()

        with patch("server.request.urlopen", fake_urlopen):
            client = DockerClient("http://proxy:2375")
            client.list_containers()
            client.inspect_container("name/with spaces")

        self.assertEqual(
            requested,
            [
                ("http://proxy:2375/containers/json?all=1", "GET", 5),
                ("http://proxy:2375/containers/name%2Fwith%20spaces/json", "GET", 5),
            ],
        )

    def test_static_resolver_allows_only_the_viewer_assets(self):
        self.assertEqual(resolve_static_path("/index.html").name, "index.html")
        self.assertIsNone(resolve_static_path("/../../runtime.py"))
        self.assertIsNone(resolve_static_path("/static/../runtime.py"))


@unittest.skipUnless(SERVER_SPEC, "server module has not been implemented yet")
class HTTPViewerTests(unittest.TestCase):
    def setUp(self):
        now = lambda: datetime(2026, 7, 12, tzinfo=timezone.utc)
        self.client = FakeDockerClient(
            [{"Id": "one", "Names": ["/grafana"], "Labels": {"com.docker.compose.project": "grafana"}}],
            {"one": {"State": {"Running": True, "Health": {"Status": "healthy"}}}},
        )
        self.server = RuntimeHTTPServer(("127.0.0.1", 0), RuntimeService(self.client, SnapshotCache(), GROUPS, now=now))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def test_healthz_is_local_and_does_not_call_docker(self):
        with urllib.request.urlopen(f"{self.base_url}/healthz") as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.read(), b"ok\n")

        self.assertEqual(self.client.list_calls, 0)

    def test_api_runtime_sends_a_safe_fresh_json_snapshot(self):
        with urllib.request.urlopen(f"{self.base_url}/api/runtime") as response:
            payload = json.loads(response.read())
            self.assertEqual(response.status, 200)
            self.assertEqual(response.headers["Cache-Control"], "no-store")
            self.assertEqual(response.headers["X-Content-Type-Options"], "nosniff")
            self.assertEqual(response.headers["Content-Type"], "application/json; charset=utf-8")

        self.assertFalse(payload["stale"])
        self.assertEqual(payload["groups"][0]["containers"][0]["status"], "healthy")

    def test_api_runtime_returns_503_json_when_docker_is_unavailable_without_cache(self):
        self.client.list_error = OSError("offline")

        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(f"{self.base_url}/api/runtime")

        self.assertEqual(caught.exception.code, 503)
        self.assertEqual(caught.exception.headers["Cache-Control"], "no-store")
        self.assertEqual(json.loads(caught.exception.read()), {"error": "Docker runtime is unavailable"})


@unittest.skipUnless(SERVER_SPEC, "server module has not been implemented yet")
class ViewerAssetTests(unittest.TestCase):
    def test_viewer_assets_use_safe_accordion_and_stale_affordances(self):
        static_dir = APP_DIR / "static"
        html = (static_dir / "index.html").read_text(encoding="utf-8")
        javascript = (static_dir / "app.js").read_text(encoding="utf-8")
        stylesheet = (static_dir / "style.css").read_text(encoding="utf-8")

        self.assertIn('id="summary"', html)
        self.assertIn('setInterval(refresh, 15000)', javascript)
        self.assertIn("aria-expanded", javascript)
        self.assertIn("aria-controls", javascript)
        self.assertIn("textContent", javascript)
        self.assertIn("stale", javascript)
        self.assertIn('healthy_count: snapshot.other.filter((item) => item.status === "healthy").length', javascript)
        for status in ("healthy", "running (no healthcheck)", "starting", "unhealthy", "completed", "stopped"):
            self.assertIn(status, javascript)
        self.assertNotIn(".status { font-weight: 700; text-transform: capitalize; }", stylesheet)


if __name__ == "__main__":
    unittest.main()
