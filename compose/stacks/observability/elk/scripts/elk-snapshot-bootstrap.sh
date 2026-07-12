#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# mgmt 호스트에서 실행. 보안 감사(acer-audit-*)를 MinIO(S3 호환) 스냅샷으로 백업한다.
#   1) ES keystore 에 S3 자격증명 등록 → reload_secure_settings
#   2) 스냅샷 repository(acer-audit-minio) 등록
#   3) SLM 정책(일일 스냅샷, 180일 보존) 적용
#
# 주의:
#   - 비밀값(S3_ACCESS_KEY/S3_SECRET_KEY)은 인자·git 에 두지 말고 Vault Agent 가
#     렌더링한 env(/run/acer-mgmt/secrets/observability/elk.env)에서 export 해서 실행.
#   - MinIO 가 같은 호스트면 물리 호스트 단일장애까지 막지는 못한다(오삭제/인덱스 손상
#     복구용). 진짜 오프호스트 DR 은 MinIO 자체를 원격 복제/백업하는 별도 정책이 필요.
# 재실행 안전: keystore add 는 -f 로 덮어쓰고, repo/SLM PUT 은 idempotent.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ES=${ES:-http://127.0.0.1:9200}
ES_CONTAINER=${ES_CONTAINER:-elasticsearch}
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # .../elk
CFG="$DIR/config"

: "${MINIO_ENDPOINT:?MINIO_ENDPOINT must be set (예: minio:9000)}"
: "${SNAPSHOT_BUCKET:?SNAPSHOT_BUCKET must be set (예: acer-es-snapshots)}"
: "${S3_ACCESS_KEY:?S3_ACCESS_KEY must be set (Vault 렌더 env 에서 export)}"
: "${S3_SECRET_KEY:?S3_SECRET_KEY must be set (Vault 렌더 env 에서 export)}"

AUTH=()
[ -n "${ES_USER:-}" ] && AUTH=(-u "${ES_USER}:${ES_PASSWORD:-}")

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# ── 1) keystore 에 S3 자격증명 ──────────────────────────────────────────────
say "ES keystore 에 S3 자격증명 등록"
printf '%s' "$S3_ACCESS_KEY" | docker exec -i "$ES_CONTAINER" \
  bin/elasticsearch-keystore add -f -x s3.client.default.access_key
printf '%s' "$S3_SECRET_KEY" | docker exec -i "$ES_CONTAINER" \
  bin/elasticsearch-keystore add -f -x s3.client.default.secret_key
curl -sf "${AUTH[@]}" -X POST "$ES/_nodes/reload_secure_settings" >/dev/null \
  && echo "  secure settings reloaded" || echo "  FAIL: reload_secure_settings"

# ── 2) 스냅샷 repository (MinIO) ─────────────────────────────────────────────
say "스냅샷 repository acer-audit-minio (bucket=$SNAPSHOT_BUCKET endpoint=$MINIO_ENDPOINT)"
curl -sf "${AUTH[@]}" -X PUT "$ES/_snapshot/acer-audit-minio" \
  -H 'Content-Type: application/json' -d "{
    \"type\": \"s3\",
    \"settings\": {
      \"bucket\": \"${SNAPSHOT_BUCKET}\",
      \"endpoint\": \"${MINIO_ENDPOINT}\",
      \"protocol\": \"http\",
      \"path_style_access\": true
    }
  }" >/dev/null && echo "  ok" || echo "  FAIL"

say "repository 검증(verify)"
curl -sf "${AUTH[@]}" -X POST "$ES/_snapshot/acer-audit-minio/_verify" >/dev/null \
  && echo "  verified" || echo "  FAIL: verify (버킷/자격증명/endpoint 확인)"

# ── 3) SLM 정책 (일일 스냅샷) ────────────────────────────────────────────────
say "SLM 정책 acer-audit-snapshot (매일 01:30, 180일 보존)"
curl -sf "${AUTH[@]}" -X PUT "$ES/_slm/policy/acer-audit-snapshot" \
  -H 'Content-Type: application/json' -d @"$CFG/snapshot/acer-audit-snapshot.slm.json" >/dev/null \
  && echo "  ok" || echo "  FAIL"

say "완료. 최초 스냅샷 즉시 실행은:  curl \"\${AUTH[@]}\" -X POST \"$ES/_slm/policy/acer-audit-snapshot/_execute\""
