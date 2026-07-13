#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FILTERS="$ROOT_DIR/compose/stacks/observability/elk/config/pipeline/20-filters.conf"
FIXTURE="$ROOT_DIR/compose/tests/fixtures/audit-normalization.generator.conf"
IMAGE="${LOGSTASH_TEST_IMAGE:-docker.elastic.co/logstash/logstash:9.4.3}"

command -v docker >/dev/null 2>&1 || { echo "FAIL: docker is required" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "FAIL: docker daemon is unavailable" >&2; exit 1; }

output="$({
  docker run --rm --network none \
    -e "LS_JAVA_OPTS=-Xms256m -Xmx256m" \
    -v "$FIXTURE:/pipeline/10-fixture.conf:ro" \
    -v "$FILTERS:/pipeline/20-filters.conf:ro" \
    "$IMAGE" -f /pipeline --log.level=error
} 2>&1)"

events="$(grep -E '^\{.*"fixture_id"' <<<"$output" || true)"
[[ -n "$events" ]] || { printf '%s\n' "$output" >&2; echo "FAIL: no fixture events returned" >&2; exit 1; }

jq -s -e '
  def event($id): map(select(.fixture_id == $id)) | first;
  (event("traefik") |
    .labels.audit_source == "traefik" and
    .http.request.method == "GET" and
    .http.response.status_code == 200 and
    .url.path == "/api/health" and
    .url.query == "full=true" and
    .event.outcome == "success" and
    .source.ip == "172.18.0.1") and
  (event("oauth2") |
    .labels.audit_source == "oauth2-proxy" and
    .event.action == "authentication" and
    .http.response.status_code == 401 and
    .event.outcome == "failure" and
    .url.path == "/oauth2/auth" and
    .trace.id == "c819a8ca-2a01-41d9-b641-8a279a7ce059") and
  (event("keycloak") |
    .labels.audit_source == "keycloak" and
    .event.action == "LOGIN" and
    .event.outcome == "success" and
    .actor.name == "mgmt" and
    .actor.id == "636c0883-4dc4-4341-a64d-5efee121740d" and
    .source.ip == "100.97.226.111") and
  (event("traefik-internal") | .labels.audit_source == null)
' <<<"$events" >/dev/null

echo "audit normalization Logstash fixture tests passed"
