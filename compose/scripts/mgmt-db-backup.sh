#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=${ENV_FILE:-/home/user1/acer-mgmt/.env}
DATA_ROOT=${DATA_ROOT:-/home/mgmt-data}
BACKUP_ROOT=${BACKUP_ROOT:-${DATA_ROOT}/backups}
MINIO_MC_IMAGE=${MINIO_MC_IMAGE:-quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z}
MINIO_NETWORK=${MINIO_NETWORK:-minio_default}
MINIO_ALIAS_URL=${MINIO_ALIAS_URL:-http://minio:9000}
MINIO_BUCKET=${MINIO_BUCKET:-db-backup}

umask 077

get_env_value() {
  local key="$1"
  local value
  value="$(grep -m1 "^${key}=" "$ENV_FILE" | cut -d= -f2- || true)"
  if [[ -z "$value" ]]; then
    echo "Missing ${key} in ${ENV_FILE}" >&2
    exit 1
  fi
  printf '%s' "$value"
}

require_container() {
  local name="$1"
  if ! docker inspect "$name" >/dev/null 2>&1; then
    echo "Required container not found: ${name}" >&2
    exit 1
  fi
}

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
postgres_dir="${BACKUP_ROOT}/supabase/postgres/${stamp}"
storage_dir="${BACKUP_ROOT}/supabase/storage/${stamp}"
config_dir="${BACKUP_ROOT}/mgmt-config/${stamp}"
k3d_dir="${BACKUP_ROOT}/k3d-mgmt-datastore/${stamp}"

mkdir -p "$postgres_dir" "$storage_dir" "$config_dir" "$k3d_dir"
chmod 700 "$postgres_dir" "$storage_dir" "$config_dir" "$k3d_dir"

require_container supabase-db
require_container minio

echo "[$(date -Is)] backing up Supabase PostgreSQL"
docker exec -u postgres supabase-db pg_dump -d postgres -Fc > "${postgres_dir}/postgres.dump"
docker exec -u postgres supabase-db pg_dumpall --globals-only > "${postgres_dir}/globals.sql"
sha256sum "${postgres_dir}/postgres.dump" "${postgres_dir}/globals.sql" > "${postgres_dir}/SHA256SUMS"

echo "[$(date -Is)] backing up Supabase Storage files"
if [[ -d "${DATA_ROOT}/supabase/storage" ]]; then
  tar -C "${DATA_ROOT}/supabase" -czf "${storage_dir}/supabase-storage.tar.gz" storage
else
  mkdir -p "${storage_dir}/empty-storage"
  tar -C "${storage_dir}" -czf "${storage_dir}/supabase-storage.tar.gz" empty-storage
  rm -rf "${storage_dir}/empty-storage"
fi
sha256sum "${storage_dir}/supabase-storage.tar.gz" > "${storage_dir}/SHA256SUMS"

echo "[$(date -Is)] backing up mgmt config and secrets"
tar -C /home/user1 -czf "${config_dir}/mgmt-config.tar.gz" \
  acer-mgmt/.env \
  acer-mgmt/compose \
  acer-mgmt/secrets \
  acer-mgmt/k3d \
  acer-argocd
sha256sum "${config_dir}/mgmt-config.tar.gz" > "${config_dir}/SHA256SUMS"

echo "[$(date -Is)] backing up mgmt k3d SQLite datastore"
python3 - "${DATA_ROOT}/k3d/mgmt/server/db/state.db" "${k3d_dir}/state.db" <<'PY'
import sqlite3
import sys

src_path, dst_path = sys.argv[1:3]
src = sqlite3.connect(src_path)
dst = sqlite3.connect(dst_path)
try:
    src.backup(dst)
finally:
    dst.close()
    src.close()
PY
if [[ -f "${DATA_ROOT}/k3d/mgmt/server/token" ]]; then
  install -m 600 "${DATA_ROOT}/k3d/mgmt/server/token" "${k3d_dir}/token"
fi
tar -C "$k3d_dir" -czf "${k3d_dir}/k3s-sqlite-datastore.tar.gz" state.db token 2>/dev/null || \
  tar -C "$k3d_dir" -czf "${k3d_dir}/k3s-sqlite-datastore.tar.gz" state.db
rm -f "${k3d_dir}/state.db" "${k3d_dir}/token"
sha256sum "${k3d_dir}/k3s-sqlite-datastore.tar.gz" > "${k3d_dir}/SHA256SUMS"

find "$postgres_dir" "$storage_dir" "$config_dir" "$k3d_dir" -type f -exec chmod 600 {} +

echo "[$(date -Is)] uploading backups to MinIO ${MINIO_BUCKET}"
MINIO_ROOT_USER="$(get_env_value MINIO_ROOT_USER)"
ADMIN_PASSWORD="$(get_env_value ADMIN_PASSWORD)"

docker run --rm --network "$MINIO_NETWORK" \
  -e MINIO_ROOT_USER="$MINIO_ROOT_USER" \
  -e ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  -v "${BACKUP_ROOT}:/backups:ro" \
  --entrypoint /bin/sh "$MINIO_MC_IMAGE" -ec "
    mc alias set local '${MINIO_ALIAS_URL}' \"\$MINIO_ROOT_USER\" \"\$ADMIN_PASSWORD\" >/dev/null
    mc mb --ignore-existing local/${MINIO_BUCKET} >/dev/null
    mc cp --recursive /backups/supabase/postgres/${stamp}/ local/${MINIO_BUCKET}/supabase-postgres/daily/${stamp}/
    mc cp --recursive /backups/supabase/storage/${stamp}/ local/${MINIO_BUCKET}/supabase-storage/daily/${stamp}/
    mc cp --recursive /backups/mgmt-config/${stamp}/ local/${MINIO_BUCKET}/mgmt-config/daily/${stamp}/
    mc cp --recursive /backups/k3d-mgmt-datastore/${stamp}/ local/${MINIO_BUCKET}/k3d-mgmt-datastore/daily/${stamp}/
  "

echo "[$(date -Is)] backup completed: ${stamp}"
