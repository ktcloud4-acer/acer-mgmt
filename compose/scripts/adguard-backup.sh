#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/backup-env.sh"

ENV_FILE=${ENV_FILE:-/home/user1/acer-mgmt/.env}
VAULT_SECRETS_ROOT=${VAULT_SECRETS_ROOT:-/home/mgmt-data/vault-agent/secrets}
MINIO_ENV=${MINIO_ENV:-${VAULT_SECRETS_ROOT}/backup-minio.env}
DATA_ROOT=${DATA_ROOT:-/home/mgmt-data}
BACKUP_ROOT=${BACKUP_ROOT:-${DATA_ROOT}/backups}
ADGUARD_DATA_DIR=${ADGUARD_DATA_DIR:-${DATA_ROOT}/adguard}
MINIO_MC_IMAGE=${MINIO_MC_IMAGE:-quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z}
MINIO_NETWORK=${MINIO_NETWORK:-minio_default}
MINIO_ALIAS_URL=${MINIO_ALIAS_URL:-http://minio:9000}
MINIO_BUCKET=${MINIO_BUCKET:-db-backup}

umask 077

require_container() {
  local name="$1"
  if ! docker inspect "$name" >/dev/null 2>&1; then
    echo "Required container not found: ${name}" >&2
    exit 1
  fi
}

if [[ ! -d "$ADGUARD_DATA_DIR/conf" ]]; then
  echo "AdGuard config directory not found: ${ADGUARD_DATA_DIR}/conf" >&2
  exit 1
fi

require_container adguard
require_container minio

stamp="$(TZ=Asia/Seoul date +%Y%m%dT%H%M%SKST)"
backup_dir="${BACKUP_ROOT}/adguard/${stamp}"
mkdir -p "$backup_dir"
chmod 700 "$backup_dir"

echo "[$(date -Is)] checking AdGuard config"
docker exec adguard /opt/adguardhome/AdGuardHome --check-config \
  -c /opt/adguardhome/conf/AdGuardHome.yaml \
  -w /opt/adguardhome/work >/dev/null

echo "[$(date -Is)] backing up AdGuard config and state"
tar -C "$ADGUARD_DATA_DIR" -czf "${backup_dir}/adguard-home.tar.gz" conf work
sha256sum "${backup_dir}/adguard-home.tar.gz" > "${backup_dir}/SHA256SUMS"
find "$backup_dir" -type f -exec chmod 600 {} +

echo "[$(date -Is)] uploading AdGuard backup to MinIO ${MINIO_BUCKET}"
MINIO_ROOT_USER="$(get_env_value "$MINIO_ENV" MINIO_ROOT_USER)"
ADMIN_PASSWORD="$(get_env_value "$MINIO_ENV" ADMIN_PASSWORD)"

docker run --rm --network "$MINIO_NETWORK" \
  -e MINIO_ROOT_USER="$MINIO_ROOT_USER" \
  -e ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  -v "${BACKUP_ROOT}:/backups:ro" \
  --entrypoint /bin/sh "$MINIO_MC_IMAGE" -ec "
    mc alias set local '${MINIO_ALIAS_URL}' \"\$MINIO_ROOT_USER\" \"\$ADMIN_PASSWORD\" >/dev/null
    mc mb --ignore-existing local/${MINIO_BUCKET} >/dev/null
    mc cp --recursive /backups/adguard/${stamp}/ local/${MINIO_BUCKET}/adguard/daily/${stamp}/
  "

echo "[$(date -Is)] AdGuard backup completed: ${stamp}"
