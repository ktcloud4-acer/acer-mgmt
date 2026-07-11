#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
filebeat="$ROOT_DIR/compose/stacks/observability/elk/config/filebeat/mgmt-docker-logstash/filebeat.yml"
filters="$ROOT_DIR/compose/stacks/observability/elk/config/pipeline/20-filters.conf"
outputs="$ROOT_DIR/compose/stacks/observability/elk/config/pipeline-consumer/90-outputs.conf"
dashboard="$ROOT_DIR/compose/stacks/observability/elk/config/kibana/security-audit.ndjson"
keycloak="$ROOT_DIR/compose/stacks/security/keycloak/compose.yaml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  [[ -f "$file" ]] || fail "missing file: $file"
  grep -Fq -- "$expected" "$file" || fail "$file does not contain: $expected"
}

assert_contains "$filebeat" "id: mgmt-vault-audit"
assert_contains "$filebeat" "/home/mgmt-data/vault-audit/vault-audit.log"
assert_contains "$filebeat" "/home/mgmt-data/wazuh/logs/alerts/alerts.json"
assert_contains "$filters" "[labels][audit_source]"
assert_contains "$filters" "[app][request][id]"
assert_contains "$filters" "[app][request][data]"
assert_contains "$outputs" "acer-audit-%{[labels][team]}"
assert_contains "$dashboard" "Security Audit Overview"
assert_contains "$keycloak" "KC_SPI_EVENTS_LISTENER__JBOSS_LOGGING__SUCCESS_LEVEL: info"

echo "security audit pipeline tests passed"
