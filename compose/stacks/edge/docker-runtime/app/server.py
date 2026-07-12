"""Read-only HTTP viewer for the Docker socket proxy."""

import json
import mimetypes
import os
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib import parse, request

from runtime import SnapshotCache, build_snapshot


APP_DIR = Path(__file__).resolve().parent
STATIC_DIR = APP_DIR / "static"
DOCKER_PROXY_URL = os.environ.get("DOCKER_PROXY_URL", "http://docker-socket-proxy:2375")
ALLOWED_DOCKER_PATHS = frozenset({"/version", "/info", "/containers/json?all=1"})
STATIC_FILES = {"/": "index.html", "/index.html": "index.html", "/app.js": "app.js", "/style.css": "style.css"}


class DockerUnavailable(Exception):
    """Docker could not be reached and there is no cached snapshot."""


class DockerClient:
    """A deliberately tiny Docker API client with no caller-provided paths."""

    def __init__(self, base_url=DOCKER_PROXY_URL):
        self.base_url = base_url.rstrip("/")

    def version(self):
        return self._get("/version")

    def info(self):
        return self._get("/info")

    def list_containers(self):
        return self._get("/containers/json?all=1")

    def inspect_container(self, container_id):
        escaped_id = parse.quote(container_id, safe="")
        return self._get(f"/containers/{escaped_id}/json", inspect_id=escaped_id)

    def _get(self, path, inspect_id=None):
        is_allowed = path in ALLOWED_DOCKER_PATHS or (
            inspect_id is not None and path == f"/containers/{inspect_id}/json"
        )
        if not is_allowed:
            raise ValueError("Docker API path is not allowed")
        http_request = request.Request(f"{self.base_url}{path}", method="GET")
        with request.urlopen(http_request, timeout=5) as response:
            return json.loads(response.read().decode("utf-8"))


class RuntimeService:
    def __init__(self, client, cache, groups, now=None):
        self.client = client
        self.cache = cache
        self.groups = groups
        self.now = now or (lambda: datetime.now(timezone.utc))

    def refresh(self):
        rows = self.client.list_containers()
        inspect_by_id = {row["Id"]: self.client.inspect_container(row["Id"]) for row in rows}
        captured_at = self._captured_at()
        snapshot = build_snapshot(rows, inspect_by_id, self.groups, captured_at)
        self.cache.record_success(snapshot, captured_at)
        return snapshot

    def runtime_data(self):
        try:
            return self.refresh()
        except OSError as error:
            stale_snapshot = self.cache.read_failure()
            if stale_snapshot is None:
                raise DockerUnavailable() from error
            return stale_snapshot

    def _captured_at(self):
        value = self.now()
        if isinstance(value, str):
            return value
        return value.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def resolve_static_path(path):
    filename = STATIC_FILES.get(path)
    if filename is None:
        return None
    candidate = (STATIC_DIR / filename).resolve()
    try:
        candidate.relative_to(STATIC_DIR.resolve())
    except ValueError:
        return None
    return candidate


class RuntimeRequestHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = parse.urlsplit(self.path).path
        if path == "/healthz":
            self._send_bytes(200, b"ok\n", "text/plain; charset=utf-8")
            return
        if path == "/api/runtime":
            self._runtime_response()
            return
        static_path = resolve_static_path(path)
        if static_path and static_path.is_file():
            self._send_bytes(200, static_path.read_bytes(), mimetypes.guess_type(static_path.name)[0] or "application/octet-stream")
            return
        self._send_bytes(404, b"not found\n", "text/plain; charset=utf-8")

    def _runtime_response(self):
        try:
            payload = self.server.runtime_service.runtime_data()
        except DockerUnavailable:
            self._send_json(503, {"error": "Docker runtime is unavailable"})
            return
        self._send_json(200, payload)

    def _send_json(self, status, payload):
        self._send_bytes(
            status,
            json.dumps(payload, separators=(",", ":")).encode("utf-8"),
            "application/json; charset=utf-8",
            {"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"},
        )

    def _send_bytes(self, status, body, content_type, extra_headers=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (extra_headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return


class RuntimeHTTPServer(ThreadingHTTPServer):
    def __init__(self, address, runtime_service):
        self.runtime_service = runtime_service
        super().__init__(address, RuntimeRequestHandler)


def load_groups():
    return json.loads((APP_DIR / "stacks.json").read_text(encoding="utf-8"))


def main():
    service = RuntimeService(DockerClient(), SnapshotCache(), load_groups())
    server = RuntimeHTTPServer(("0.0.0.0", int(os.environ.get("PORT", "8080"))), service)
    server.serve_forever()


if __name__ == "__main__":
    main()
