import importlib.util
import pathlib
import unittest
from unittest.mock import patch


SERVER_PATH = pathlib.Path(__file__).parents[1] / "app" / "server.py"


def load_server_module():
    import http.server

    original_server = http.server.ThreadingHTTPServer

    class NoopServer:
        def __init__(self, *_args, **_kwargs):
            pass

        def serve_forever(self):
            return None

    http.server.ThreadingHTTPServer = NoopServer
    try:
        spec = importlib.util.spec_from_file_location("platform_monitor_server", SERVER_PATH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        http.server.ThreadingHTTPServer = original_server


class ProbeSummaryTests(unittest.TestCase):
    def test_splits_platform_and_cluster_endpoints(self):
        server = load_server_module()
        probes = [
            {"metric": {"scope": "infra", "service": "grafana"}, "value": [0, "1"]},
            {"metric": {"scope": "infra", "service": "vault"}, "value": [0, "1"]},
            {"metric": {"scope": "team", "cluster": "ggg", "service": "ggg-dashboard"}, "value": [0, "1"]},
            {"metric": {"scope": "team", "cluster": "ggg", "service": "ggg-api"}, "value": [0, "1"]},
            {"metric": {"scope": "team", "cluster": "khb", "service": "khb-dashboard"}, "value": [0, "0"]},
            {"metric": {"scope": "team", "cluster": "khb", "service": "khb-api"}, "value": [0, "0"]},
        ]

        summary = server.summarize_probes(probes)

        self.assertEqual(summary["platform_services"], {"grafana": 1.0, "vault": 1.0})
        self.assertEqual(summary["clusters"]["ggg"], {"healthy": True, "healthy_count": 2, "total": 2})
        self.assertEqual(summary["clusters"]["khb"], {"healthy": False, "healthy_count": 0, "total": 2})
        self.assertEqual(summary["cluster_endpoint_totals"], {"healthy": 2, "total": 4})

    def test_chaos_health_requires_a_successful_upstream_response(self):
        server = load_server_module()

        with patch.object(server, "probe_chaos_upstream", return_value=200):
            self.assertTrue(server.chaos_endpoint_healthy("ggg"))

        with patch.object(server, "probe_chaos_upstream", return_value=502):
            self.assertFalse(server.chaos_endpoint_healthy("khb"))

        with patch.object(server, "probe_chaos_upstream", side_effect=TimeoutError):
            self.assertFalse(server.chaos_endpoint_healthy("nmg"))


if __name__ == "__main__":
    unittest.main()
