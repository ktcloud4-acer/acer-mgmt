#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# mgmt 호스트에서 실행. 로그 파이프라인의 "보존정책 + 시각화 발판"을 idempotent 하게 적용한다.
#   1) ES  : ILM 정책(14일 삭제) + k8s-logs-*/infra-logs-* 인덱스 템플릿(replica0) + 기존 인덱스 보정
#   2) Kibana : 팀원별 Space + Space별 data view(k8s/infra) + "errors" 저장검색
#
# 주의: W0 부터 xpack.security 가 켜진다. 이 스크립트가 ES/Kibana API 를 호출하므로
#       ES_USER/ES_PASSWORD(예: elastic) 를 export 하고 실행해야 한다:
#         set -a; . /run/acer-mgmt/secrets/observability/elk.env; set +a
#         ES_USER=elastic ES_PASSWORD="$ELK_ELASTIC_PASSWORD" ./apply-observability.sh
#       Kibana Space 는 여전히 "조직적 분리"이며, 사람 접근 게이트는 앞단 oauth2-proxy 다.
#       팀별 문서레벨 격리(감사 인덱스 제외)는 Basic 에선 native 계정/역할로 별도 설계.
# 재실행 안전: data view/저장검색은 고정 id + overwrite, Space 는 이미 있으면 409(무시).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ES=${ES:-http://127.0.0.1:9200}
KB=${KB:-http://127.0.0.1:5601}
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # .../elk
CFG="$DIR/config"
USERS=(ggg khb ljw nmg oje)

# xpack.security 가 켜져 있으면 ES_USER/ES_PASSWORD 로 인증한다(끄면 무시).
# 비밀값은 인자로 넘기지 말고 Vault Agent 가 렌더링한 env 로 export 해서 실행할 것.
AUTH=()
[ -n "${ES_USER:-}" ] && AUTH=(-u "${ES_USER}:${ES_PASSWORD:-}")

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# ── 1) Elasticsearch: 보존정책 ──────────────────────────────────────────────
say "ILM 정책 logs-retention-14d"
curl -sf "${AUTH[@]}" -X PUT "$ES/_ilm/policy/logs-retention-14d" \
  -H 'Content-Type: application/json' -d @"$CFG/ilm/logs-retention-14d.policy.json" >/dev/null \
  && echo "  ok" || echo "  FAIL"

say "인덱스 템플릿 acer-logs (k8s-logs-*, infra-logs-*)"
curl -sf "${AUTH[@]}" -X PUT "$ES/_index_template/acer-logs" \
  -H 'Content-Type: application/json' -d @"$CFG/ilm/acer-logs.template.json" >/dev/null \
  && echo "  ok" || echo "  FAIL"

say "기존 k8s-logs-*/infra-logs-* 인덱스에 replica0 + lifecycle 적용 (yellow→green + 보존 소급)"
curl -sf "${AUTH[@]}" -X PUT "$ES/k8s-logs-*,infra-logs-*/_settings" \
  -H 'Content-Type: application/json' \
  -d '{"index":{"number_of_replicas":0,"lifecycle":{"name":"logs-retention-14d"}}}' >/dev/null \
  && echo "  ok" || echo "  (대상 인덱스 없음 or 부분실패 — 신규 인덱스는 템플릿으로 커버됨)"

# ── 1b) 보안 감사(acer-audit-*): 전용 보존 ILM + replica0 템플릿 ─────────────
# 감사 인덱스는 일반 로그(14d)보다 길게 보존하고, 일반 로그 삭제정책에 절대 잡히지
# 않도록 별도 정책/템플릿을 쓴다. 지금까지 이 인덱스들은 ILM 미적용(managed:false)
# 이라 무한 증가 + 단일노드 replica1 로 yellow 였다.
say "ILM 정책 acer-audit-retention (감사 90일 보존)"
curl -sf "${AUTH[@]}" -X PUT "$ES/_ilm/policy/acer-audit-retention" \
  -H 'Content-Type: application/json' -d @"$CFG/ilm/acer-audit-retention.policy.json" >/dev/null \
  && echo "  ok" || echo "  FAIL"

say "인덱스 템플릿 acer-audit (acer-audit-*)"
curl -sf "${AUTH[@]}" -X PUT "$ES/_index_template/acer-audit" \
  -H 'Content-Type: application/json' -d @"$CFG/ilm/acer-audit.template.json" >/dev/null \
  && echo "  ok" || echo "  FAIL"

say "기존 acer-audit-* 인덱스에 replica0 + 감사 lifecycle 소급 (yellow→green + 보존 부착)"
curl -sf "${AUTH[@]}" -X PUT "$ES/acer-audit-*/_settings" \
  -H 'Content-Type: application/json' \
  -d '{"index":{"number_of_replicas":0,"lifecycle":{"name":"acer-audit-retention"}}}' >/dev/null \
  && echo "  ok" || echo "  (대상 인덱스 없음 or 부분실패 — 신규 인덱스는 템플릿으로 커버됨)"

# ── 2) Kibana: 팀원별 Space + data view + 저장검색 ─────────────────────────
KBH=(-H 'kbn-xsrf: true' -H 'Content-Type: application/json' "${AUTH[@]}")

mk_dataview() {  # space title id
  local space=$1 title=$2 id=$3 base=$KB
  [ "$space" != "-" ] && base="$KB/s/$space"
  curl -s -X POST "$base/api/data_views/data_view" "${KBH[@]}" \
    -d "{\"data_view\":{\"id\":\"$id\",\"title\":\"$title\",\"name\":\"$title\",\"timeFieldName\":\"@timestamp\"}}" \
    -o /dev/null -w "    data_view $id http=%{http_code}\n"
}

for u in "${USERS[@]}"; do
  say "Kibana Space: $u"
  curl -s -X POST "$KB/api/spaces/space" "${KBH[@]}" \
    -d "{\"id\":\"$u\",\"name\":\"$u\",\"description\":\"$u 팀 클러스터 로그\",\"disabledFeatures\":[]}" \
    -o /dev/null -w "    space $u http=%{http_code} (409=이미존재)\n"
  mk_dataview "$u" "k8s-logs-$u-*"   "dv-k8s-$u"
  mk_dataview "$u" "infra-logs-$u-*" "dv-infra-$u"

  # "errors" 저장검색: 해당 팀 k8s 로그 중 ERROR/FATAL/CRITICAL 만
  curl -s -X POST "$KB/s/$u/api/saved_objects/search/errors-$u?overwrite=true" "${KBH[@]}" -d "{
    \"attributes\": {
      \"title\": \"errors — $u\",
      \"description\": \"log.level 이 ERROR/FATAL/CRITICAL 인 로그만\",
      \"columns\": [\"kubernetes.namespace\",\"kubernetes.pod.name\",\"log.level\",\"message\"],
      \"sort\": [[\"@timestamp\",\"desc\"]],
      \"kibanaSavedObjectMeta\": {
        \"searchSourceJSON\": \"{\\\"query\\\":{\\\"language\\\":\\\"kuery\\\",\\\"query\\\":\\\"log.level : (ERROR or FATAL or CRITICAL)\\\"},\\\"filter\\\":[],\\\"indexRefName\\\":\\\"kibanaSavedObjectMeta.searchSourceJSON.index\\\"}\"
      }
    },
    \"references\": [
      {\"id\":\"dv-k8s-$u\",\"name\":\"kibanaSavedObjectMeta.searchSourceJSON.index\",\"type\":\"index-pattern\"}
    ]
  }" -o /dev/null -w "    saved-search errors-$u http=%{http_code}\n"
done

# default(admin) space: 전체 클러스터 조회용 data view
say "default space: 전체 조회용 data view"
mk_dataview "-" "k8s-logs-*,infra-logs-*" "dv-all-cluster-logs"
mk_dataview "-" "service-logs-mgmt-*"      "dv-mgmt-service-logs"

say "완료. Kibana → 우상단 Space 전환 → Discover 에서 팀별 로그 확인."
