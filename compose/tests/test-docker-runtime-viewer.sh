#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STACK_DIR="${REPO_ROOT}/compose/stacks/edge/docker-runtime"
COMPOSE_FILE="${STACK_DIR}/compose.yaml"
DOCKERFILE="${STACK_DIR}/Dockerfile"
MIDDLEWARES_FILE="${REPO_ROOT}/compose/stacks/edge/traefik/config/dynamic/middlewares.yaml"

fail() {
  echo "DOCKER_RUNTIME_VIEWER_CONTRACT=FAIL: $*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

assert_contains() {
  grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"
}

assert_not_contains() {
  ! grep -Fq -- "$2" "$1" || fail "did not expect '$2' in $1"
}

service_block() {
  awk -v service="$1" '
    $0 == "  " service ":" { in_service = 1; next }
    in_service && $0 ~ /^  [[:alnum:]_-]+:$/ { exit }
    in_service { print }
  ' "$COMPOSE_FILE"
}

assert_service_contains() {
  local service="$1"
  local expected="$2"
  service_block "$service" | grep -Fq -- "$expected" \
    || fail "expected '$expected' in ${service} service"
}

assert_service_not_contains() {
  local service="$1"
  local unexpected="$2"
  ! service_block "$service" | grep -Fq -- "$unexpected" \
    || fail "did not expect '$unexpected' in ${service} service"
}

assert_socket_proxy_permissions() {
  local expected actual
  expected="$(printf '%s\n' AUTH CONTAINERS EVENTS EXEC IMAGES INFO NETWORKS POST SECRETS VERSION VOLUMES | sort)"
  actual="$(service_block docker-socket-proxy | awk '
    $0 == "    environment:" { in_environment = 1; next }
    in_environment && /^    [[:alnum:]_-]+:/ { exit }
    in_environment && /^      [A-Z_]+:/ { sub(/:.*/, ""); sub(/^[[:space:]]+/, ""); print }
  ' | sort)"
  [[ "$actual" == "$expected" ]] || fail "socket proxy endpoint permissions must be exactly the approved allow/deny set"
}

assert_service_networks() {
  local service="$1"
  local expected="$2"
  local actual
  actual="$(service_block "$service" | awk '
    $0 == "    networks:" { in_networks = 1; next }
    in_networks && /^    [[:alnum:]_-]+:/ { exit }
    in_networks && /^      [[:alnum:]_-]+:/ { sub(/:.*/, ""); sub(/^[[:space:]]+/, ""); print }
  ' | sort)"
  [[ "$actual" == "$expected" ]] || fail "${service} has unexpected networks"
}

assert_file "$COMPOSE_FILE"
assert_file "$DOCKERFILE"
assert_file "$MIDDLEWARES_FILE"

assert_contains "$DOCKERFILE" 'FROM python:3.13-alpine'
assert_contains "$DOCKERFILE" 'COPY app/ app/'
assert_contains "$DOCKERFILE" 'addgroup -g 10001 app'
assert_contains "$DOCKERFILE" 'adduser -D -H -u 10001 -G app app'
assert_contains "$DOCKERFILE" 'USER 10001:10001'
assert_contains "$DOCKERFILE" 'EXPOSE 8080'
assert_contains "$DOCKERFILE" 'CMD ["python", "-m", "app.server"]'

assert_service_contains docker-socket-proxy 'image: tecnativa/docker-socket-proxy:v0.4.2'
assert_service_contains docker-socket-proxy '/var/run/docker.sock:/var/run/docker.sock:ro'
for permission in 'POST: "0"' 'AUTH: "0"' 'SECRETS: "0"' 'EXEC: "0"' 'IMAGES: "0"' 'NETWORKS: "0"' 'VOLUMES: "0"' 'EVENTS: "0"' 'CONTAINERS: "1"' 'INFO: "1"' 'VERSION: "1"'; do
  assert_service_contains docker-socket-proxy "$permission"
done
assert_socket_proxy_permissions

for service in docker-socket-proxy docker-runtime-viewer; do
  assert_service_contains "$service" 'read_only: true'
  assert_service_contains "$service" 'no-new-privileges:true'
  assert_service_contains "$service" '- ALL'
  assert_service_contains "$service" '- /tmp'
  assert_service_not_contains "$service" 'privileged: true'
  assert_service_not_contains "$service" 'ports:'
done

assert_service_contains docker-socket-proxy 'docker-runtime-socket:'
assert_service_not_contains docker-socket-proxy 'mgmt-proxy:'
assert_service_not_contains docker-socket-proxy 'traefik.'
assert_service_not_contains docker-socket-proxy 'external: true'
assert_service_networks docker-socket-proxy 'docker-runtime-socket'

assert_service_contains docker-runtime-viewer 'build: .'
assert_service_contains docker-runtime-viewer 'DOCKER_PROXY_URL: http://docker-socket-proxy:2375'
assert_service_contains docker-runtime-viewer 'mgmt-proxy:'
assert_service_contains docker-runtime-viewer 'docker-runtime-socket:'
assert_service_not_contains docker-runtime-viewer '/var/run/docker.sock'
assert_service_networks docker-runtime-viewer "$(printf '%s\n' docker-runtime-socket mgmt-proxy | sort)"
assert_service_contains docker-runtime-viewer 'wget -q --spider http://127.0.0.1:8080/healthz'
assert_service_contains docker-runtime-viewer 'traefik.http.routers.docker-runtime.rule=Host(`runtime.${BASE_DOMAIN}`)'
assert_service_contains docker-runtime-viewer 'traefik.http.routers.docker-runtime.middlewares=sso-auth@file,docker-runtime-iframe@file'
assert_service_contains docker-runtime-viewer 'traefik.http.services.docker-runtime.loadbalancer.server.port=8080'

assert_contains "$MIDDLEWARES_FILE" 'docker-runtime-iframe:'
assert_contains "$MIDDLEWARES_FILE" 'frame-ancestors https://dashy.imcherry5778.xyz'
assert_contains "$MIDDLEWARES_FILE" 'X-Frame-Options: ""'
assert_not_contains "$MIDDLEWARES_FILE" 'frame-ancestors *'

assert_not_contains "$COMPOSE_FILE" 'ports:'
assert_not_contains "$COMPOSE_FILE" 'privileged: true'

echo 'DOCKER_RUNTIME_VIEWER_CONTRACT=PASS'
