#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# mgmt 호스트에서 실행. xpack.security 활성 후 최초 1회(및 재실행 안전) 부트스트랩.
#   1) kibana_system 내장계정 패스워드 설정 (Kibana ↔ ES)
#   2) logstash_writer role(=delete 불가) + logstash_ingest 계정 (최소권한 색인)
#   3) acer_audit_viewer role (감사 인덱스 read-only, 사람/자동화 조사용)
#
# 전제: elasticsearch 컨테이너가 xpack.security.enabled=true 로 이미 기동돼 있고,
#       ELASTIC_PASSWORD(=ELK_ELASTIC_PASSWORD)로 최초 elastic 패스워드가 설정된 상태.
# 비밀값은 인자·git 금지. Vault Agent 렌더 env 에서 export 해서 실행:
#   set -a; . /run/acer-mgmt/secrets/observability/elk.env; set +a; ./elk-security-bootstrap.sh
# 재실행 안전: 패스워드 설정/role PUT/user PUT 모두 idempotent.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ES=${ES:-http://127.0.0.1:9200}
: "${ELK_ELASTIC_PASSWORD:?ELK_ELASTIC_PASSWORD must be set (elastic superuser)}"
: "${ELK_KIBANA_PASSWORD:?ELK_KIBANA_PASSWORD must be set (kibana_system)}"
: "${ELK_LOGSTASH_PASSWORD:?ELK_LOGSTASH_PASSWORD must be set (logstash_ingest)}"
LOGSTASH_USER=${ELK_LOGSTASH_USER:-logstash_ingest}

A=(-u "elastic:${ELK_ELASTIC_PASSWORD}")
say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
jput() { curl -sf "${A[@]}" -X "$1" "$ES$2" -H 'Content-Type: application/json' -d "$3" >/dev/null; }

# ── 0) ES 준비 대기 ─────────────────────────────────────────────────────────
say "ES 인증 확인"
for i in $(seq 1 30); do
  curl -sf "${A[@]}" "$ES/_cluster/health" >/dev/null && { echo "  ok"; break; }
  [ "$i" = 30 ] && { echo "  FAIL: elastic 인증 실패(패스워드/보안설정 확인)"; exit 1; }
  sleep 3
done

# ── 1) kibana_system 패스워드 ───────────────────────────────────────────────
say "kibana_system 패스워드 설정"
jput POST "/_security/user/kibana_system/_password" \
  "{\"password\":\"${ELK_KIBANA_PASSWORD}\"}" && echo "  ok" || echo "  FAIL"

# ── 2) logstash_writer role(삭제 불가) + logstash_ingest 계정 ───────────────
say "role logstash_writer (색인 전용, delete_index 없음)"
jput PUT "/_security/role/logstash_writer" '{
  "cluster": ["monitor"],
  "indices": [
    {
      "names": ["acer-audit-*","acer-*","logs-*","k8s-logs-*","infra-logs-*","service-logs-*"],
      "privileges": ["create_index","create","index","write","view_index_metadata","auto_configure"]
    }
  ]
}' && echo "  ok" || echo "  FAIL"

say "user ${LOGSTASH_USER}"
jput PUT "/_security/user/${LOGSTASH_USER}" "{
  \"password\": \"${ELK_LOGSTASH_PASSWORD}\",
  \"roles\": [\"logstash_writer\"],
  \"full_name\": \"Logstash ingest (W0 least-privilege)\"
}" && echo "  ok" || echo "  FAIL"

# ── 3) acer_audit_viewer role (감사 read-only) ──────────────────────────────
say "role acer_audit_viewer (acer-audit-* read-only)"
jput PUT "/_security/role/acer_audit_viewer" '{
  "cluster": [],
  "indices": [
    { "names": ["acer-audit-*"], "privileges": ["read","view_index_metadata"] }
  ]
}' && echo "  ok" || echo "  FAIL"

say "완료. 다음: Kibana/Logstash-consumer 를 자격증명과 함께 재기동하고 apply-observability.sh 를 ES_USER=elastic 으로 재실행."
