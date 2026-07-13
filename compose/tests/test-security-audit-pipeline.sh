#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
filebeat="$ROOT_DIR/compose/stacks/observability/elk/config/filebeat/mgmt-docker-logstash/filebeat.yml"
filters="$ROOT_DIR/compose/stacks/observability/elk/config/pipeline/20-filters.conf"
outputs="$ROOT_DIR/compose/stacks/observability/elk/config/pipeline-consumer/90-outputs.conf"
dashboard="$ROOT_DIR/compose/stacks/observability/elk/config/kibana/security-audit.dashboard.json"
keycloak="$ROOT_DIR/compose/stacks/security/keycloak/compose.yaml"
elk="$ROOT_DIR/compose/stacks/observability/elk"
compose="$elk/compose.yaml"
audit_policy="$elk/config/ilm/acer-audit-retention.policy.json"
audit_template="$elk/config/ilm/acer-audit.template.json"
audit_mapping="$elk/config/ilm/acer-audit.fields.mapping.json"
logs_template="$elk/config/elasticsearch/acer-logs-template.json"
apply="$elk/scripts/apply-observability.sh"
sec_bootstrap="$elk/scripts/elk-security-bootstrap.sh"
snap_bootstrap="$elk/scripts/elk-snapshot-bootstrap.sh"
slm="$elk/config/snapshot/acer-audit-snapshot.slm.json"
alerts="$elk/config/pipeline/50-audit-alerts.conf"
normalization_test="$ROOT_DIR/compose/tests/test-audit-normalization-logstash.sh"
normalization_fixture="$ROOT_DIR/compose/tests/fixtures/audit-normalization.generator.conf"

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

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  [[ -f "$file" ]] || fail "missing file: $file"
  grep -Fq -- "$unexpected" "$file" && fail "$file contains obsolete value: $unexpected"
  return 0
}

assert_dashboard_contract() {
  local file="$1"
  [[ -f "$file" ]] || fail "missing file: $file"
  command -v node >/dev/null 2>&1 || fail "node is required to validate dashboard JSON"
  node "$ROOT_DIR/compose/tests/validate-security-audit-dashboard.mjs" "$file"
}

assert_contains "$filebeat" "id: mgmt-vault-audit"
assert_contains "$filebeat" "/home/mgmt-data/vault-audit/vault-audit.log"
assert_contains "$filebeat" "/home/mgmt-data/wazuh/logs/alerts/alerts.json"
assert_contains "$filebeat" "drop_event:"
assert_contains "$filebeat" "container.name: logstash"
assert_contains "$filebeat" "container.name: logstash-consumer"
assert_not_contains "$filebeat" "      user: mgmt"
assert_contains "$filters" "[labels][audit_source]"
assert_contains "$filters" "[app][request][id]"
assert_contains "$filters" "[app][request][data]"
assert_contains "$filters" 'if [host][name] == "acer-mgmt" and [container][name] in ["logstash", "logstash-consumer"]'
assert_contains "$filters" 'if [container][name] =~ /^\/?traefik$/ and [message] =~ /HTTP\/[0-9.]+" [0-9]{3} /'
assert_contains "$filters" 'if [container][name] =~ /^\/?oauth2-proxy$/ and [message] =~ /HTTP\/[0-9.]+/'
assert_contains "$filters" 'if [container][name] =~ /^\/?keycloak$/ and [message] =~ /\[org\.keycloak\.events\]/'
assert_contains "$filters" '"[actor][name]"'
assert_contains "$filters" '"[observer][name]"'
assert_contains "$filters" '[http][request][method]'
assert_contains "$filters" '"[http][response][status_code]"'
assert_contains "$filters" '"[event][outcome]"'
assert_not_contains "$filters" 'if [container][name] =~ /^\/?(keycloak|oauth2-proxy|traefik)$/'
assert_contains "$normalization_test" "audit normalization Logstash fixture tests passed"
assert_contains "$normalization_fixture" '"fixture_id":"traefik-internal"'
assert_contains "$outputs" "acer-audit-%{[labels][team]}"
assert_dashboard_contract "$dashboard"
assert_contains "$dashboard" '"title": "Security Audit Overview"'
assert_contains "$dashboard" '"type": "options_list_control"'
assert_contains "$dashboard" '"field_name": "labels.audit_source.keyword"'
assert_contains "$dashboard" '"field_name": "labels.team.keyword"'
assert_contains "$dashboard" '"field_name": "labels.audit_alert"'
assert_contains "$dashboard" '"field_name": "actor.name"'
assert_contains "$dashboard" '"field_name": "host.name.keyword"'
assert_not_contains "$dashboard" 'labels.audit_alert.keyword'
assert_not_contains "$dashboard" 'user.name'
assert_not_contains "$dashboard" 'user.keyword'
assert_contains "$dashboard" '"column": "actor.name"'
assert_contains "$dashboard" '"title": "Wazuh audit events"'
assert_contains "$dashboard" 'SET unmapped_fields=\"NULLIFY\"; FROM acer-audit-* METADATA _index'
assert_contains "$dashboard" "Current situation"
assert_contains "$dashboard" "Source freshness"
assert_contains "$dashboard" "Recent high-signal events"
assert_contains "$dashboard" "Access and authentication"
assert_contains "$dashboard" "Recent proxy access"
assert_contains "$dashboard" "Authentication failures"
assert_contains "$dashboard" "Top requested paths"
assert_contains "$dashboard" "Security domains"
assert_contains "$dashboard" "Identity and privileged activity"
assert_contains "$dashboard" "Wazuh host security"
assert_contains "$dashboard" "Full audit timeline"
assert_contains "$dashboard" 'NOT (_index LIKE \"acer-audit-alerts-*\")'
assert_contains "$dashboard" '"id": "audit-kpi-total"'
assert_contains "$apply" "acer-audit-*,-acer-audit-alerts-*"
assert_contains "$apply" '\"allowNoIndex\":true'
assert_contains "$apply" "/api/dashboards/security-audit-overview"
assert_contains "$apply" "security-audit.dashboard.json"
assert_contains "$apply" "dashboard verification failed"
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
node -e '
  const fs = require("node:fs");
  const template = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (template.template?.mappings?.properties?.labels?.properties?.audit_alert?.type !== "keyword") {
    throw new Error("labels.audit_alert must be mapped as keyword");
  }
' "$audit_template"
node -e '
  const fs = require("node:fs");
  const template = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const mapping = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const expected = mapping.properties;
  const actual = template.template?.mappings?.properties;
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error("audit template mappings and existing-index mapping must match");
  }
  const required = {
    "actor.name": actual?.actor?.properties?.name?.type,
    "observer.name": actual?.observer?.properties?.name?.type,
    "source.ip": actual?.source?.properties?.ip?.type,
    "http.request.method": actual?.http?.properties?.request?.properties?.method?.type,
    "http.response.status_code": actual?.http?.properties?.response?.properties?.status_code?.type,
    "event.outcome": actual?.event?.properties?.outcome?.type,
  };
  for (const [field, type] of Object.entries(required)) {
    if (!type) throw new Error(`missing explicit mapping for ${field}`);
  }
' "$audit_template" "$audit_mapping"
assert_contains "$apply" "acer-audit-retention"
assert_contains "$apply" "_index_template/acer-audit"
assert_contains "$apply" 'acer-audit-*/_mapping'
assert_contains "$apply" '$CFG/ilm/acer-audit.fields.mapping.json'
assert_contains "$logs_template" '"logs-docker-*"'
assert_contains "$logs_template" '"priority": 250'
assert_contains "$apply" '$CFG/elasticsearch/acer-logs-template.json'
grep -Fq '$CFG/ilm/acer-logs.template.json' "$apply" \
  && fail "apply-observability must not deploy the legacy acer-logs template" || true

# ── W0 P2b: 스냅샷 ───────────────────────────────────────────────────────────
assert_contains "$slm" '"repository": "acer-audit-minio"'
assert_contains "$snap_bootstrap" "elasticsearch-keystore add"
assert_contains "$snap_bootstrap" "_slm/policy/acer-audit-snapshot"

# ── W0 P3: 탐지 + 전용 알림 인덱스 ──────────────────────────────────────────
assert_contains "$alerts" "vault-root-token-used"
assert_contains "$alerts" "wazuh-high-severity"
assert_contains "$outputs" "acer-audit-alerts-%{[labels][team]}"

echo "security audit pipeline tests passed"
