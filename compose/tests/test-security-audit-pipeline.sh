#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
filebeat="$ROOT_DIR/compose/stacks/observability/elk/config/filebeat/mgmt-docker-logstash/filebeat.yml"
filters="$ROOT_DIR/compose/stacks/observability/elk/config/pipeline/20-filters.conf"
outputs="$ROOT_DIR/compose/stacks/observability/elk/config/pipeline-consumer/90-outputs.conf"
dashboard="$ROOT_DIR/compose/stacks/observability/elk/config/kibana/security-audit.ndjson"
keycloak="$ROOT_DIR/compose/stacks/security/keycloak/compose.yaml"
elk="$ROOT_DIR/compose/stacks/observability/elk"
compose="$elk/compose.yaml"
audit_policy="$elk/config/ilm/acer-audit-retention.policy.json"
audit_template="$elk/config/ilm/acer-audit.template.json"
apply="$elk/scripts/apply-observability.sh"
sec_bootstrap="$elk/scripts/elk-security-bootstrap.sh"
snap_bootstrap="$elk/scripts/elk-snapshot-bootstrap.sh"
slm="$elk/config/snapshot/acer-audit-snapshot.slm.json"
alerts="$elk/config/pipeline/50-audit-alerts.conf"

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

# ── W0 P1: ES security + 최소권한 RBAC ───────────────────────────────────────
assert_contains "$compose" 'xpack.security.enabled: "true"'
assert_contains "$compose" "ELASTICSEARCH_USERNAME: kibana_system"
assert_contains "$compose" "ELASTIC_PASSWORD: \${ELK_ELASTIC_PASSWORD"
assert_contains "$compose" "ES_USER: \${ELK_LOGSTASH_USER"
# 12개 ES output 모두 인증(user/password)
[[ "$(grep -c 'user => "${ES_USER}"' "$outputs")" -ge 12 ]] || fail "not all ES outputs authenticated"
assert_contains "$sec_bootstrap" "logstash_writer"
assert_contains "$sec_bootstrap" "acer_audit_viewer"
assert_contains "$sec_bootstrap" "/_security/user/kibana_system/_password"
# 색인 계정에 delete_index/manage 권한이 없어야 감사 이력 삭제 불가
# (주석이 아니라 실제 권한 값 — 따옴표로 감싼 privilege 문자열만 검사)
grep -Eq '"(delete_index|delete|manage|all)"' "$sec_bootstrap" && fail "logstash writer must not have delete/manage/all privilege" || true

# ── W0 P2: 감사 전용 ILM + replica0 템플릿 ──────────────────────────────────
# 정책 이름은 apply 스크립트의 URL 에서 바인딩 → 여기선 본문(90일 delete)만 검증
assert_contains "$audit_policy" '"min_age": "90d"'
assert_contains "$audit_policy" '"delete"'
assert_contains "$audit_template" '"acer-audit-*"'
assert_contains "$audit_template" '"number_of_replicas": 0'
assert_contains "$apply" "acer-audit-retention"
assert_contains "$apply" "_index_template/acer-audit"

# ── W0 P2b: 스냅샷 ───────────────────────────────────────────────────────────
assert_contains "$slm" '"repository": "acer-audit-minio"'
assert_contains "$snap_bootstrap" "elasticsearch-keystore add"
assert_contains "$snap_bootstrap" "_slm/policy/acer-audit-snapshot"

# ── W0 P3: 탐지 + 전용 알림 인덱스 ──────────────────────────────────────────
assert_contains "$alerts" "vault-root-token-used"
assert_contains "$alerts" "wazuh-high-severity"
assert_contains "$outputs" "acer-audit-alerts-%{[labels][team]}"

echo "security audit pipeline tests passed"
