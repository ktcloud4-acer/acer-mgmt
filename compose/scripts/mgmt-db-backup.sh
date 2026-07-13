#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/backup-env.sh"

ENV_FILE=${ENV_FILE:-/home/user1/acer-mgmt/.env}
VAULT_SECRETS_ROOT=${VAULT_SECRETS_ROOT:-/home/mgmt-data/vault-agent/secrets}
MINIO_ENV=${MINIO_ENV:-${VAULT_SECRETS_ROOT}/backup-minio.env}
DATA_ROOT=${DATA_ROOT:-/home/mgmt-data}
BACKUP_ROOT=${BACKUP_ROOT:-${DATA_ROOT}/backups}
MINIO_MC_IMAGE=${MINIO_MC_IMAGE:-quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z}
MINIO_NETWORK=${MINIO_NETWORK:-minio_default}
MINIO_ALIAS_URL=${MINIO_ALIAS_URL:-http://minio:9000}
MINIO_BUCKET=${MINIO_BUCKET:-db-backup}
VAULT_CONTAINER=${VAULT_CONTAINER:-vault}
NODE_EXPORTER_TEXTFILE=${NODE_EXPORTER_TEXTFILE:-${DATA_ROOT}/node-exporter-textfile}
BACKUP_LOCK_FILE=${BACKUP_LOCK_FILE:-${DATA_ROOT}/locks/mgmt-db-backup.lock}
BACKUP_FLOCK_BIN=${BACKUP_FLOCK_BIN:-flock}

umask 077

require_container() {
  local name="$1"
  if ! docker inspect "$name" >/dev/null 2>&1; then
    echo "Required container not found: ${name}" >&2
    exit 1
  fi
}

acquire_backup_lock() {
  if ! command -v "$BACKUP_FLOCK_BIN" >/dev/null 2>&1; then
    echo "Required lock command not found: ${BACKUP_FLOCK_BIN}" >&2
    return 1
  fi
  mkdir -p "$(dirname "$BACKUP_LOCK_FILE")" || return 1
  chmod 700 "$(dirname "$BACKUP_LOCK_FILE")" || return 1
  exec {BACKUP_LOCK_FD}>"$BACKUP_LOCK_FILE" || return 1
  if ! "$BACKUP_FLOCK_BIN" -n "$BACKUP_LOCK_FD"; then
    echo "Another mgmt backup is already running: ${BACKUP_LOCK_FILE}" >&2
    exec {BACKUP_LOCK_FD}>&-
    return 1
  fi
}

create_config_backup() {
  local archive_path="$1"
  local home_root="${2:-/home/user1}"
  local paths=(
    acer-mgmt/.env
    acer-mgmt/compose
    acer-mgmt/secrets
    acer-mgmt/k3d
  )

  if [[ -e "${home_root}/acer-argocd" ]]; then
    paths+=(acer-argocd)
  fi

  tar -C "$home_root" -czf "$archive_path" \
    --exclude='vault.snap' --exclude='*/vault.snap' \
    --exclude='.vt' --exclude='*/.vt' \
    --exclude='intermediate-ca.pem' --exclude='*/intermediate-ca.pem' \
    --exclude='.intermediate-ca.pem.*' --exclude='*/.intermediate-ca.pem.*' \
    "${paths[@]}"
}

create_vault_raft_snapshot() (
  set -euo pipefail

  local destination="$1"
  local snapshot_tmp="${destination}/vault.snap.tmp"
  local inspect_tmp="${destination}/inspect.txt.tmp"
  local checksum_tmp="${destination}/SHA256SUMS.tmp"
  local ca_tmp="${destination}/intermediate-ca.pem"
  local metric_tmp=''
  local not_after intermediate_expiry
  local complete=0
  local destination_created=0

  cleanup_vault_snapshot_attempt() {
    if [[ "$destination_created" == 1 ]]; then
      rm -f "$snapshot_tmp" "$inspect_tmp" "$checksum_tmp" "$ca_tmp"
      [[ -z "$metric_tmp" ]] || rm -f "$metric_tmp"
    fi
    if [[ "$destination_created" == 1 && "$complete" != 1 ]]; then
      rm -rf "$destination"
    fi
  }
  trap cleanup_vault_snapshot_attempt EXIT

  mkdir -p "$(dirname "$destination")" || exit 1
  mkdir "$destination" || exit 1
  destination_created=1
  chmod 700 "$destination" || exit 1

  docker exec "$VAULT_CONTAINER" sh -ceu '
    export VAULT_ADDR=https://127.0.0.1:8200
    export VAULT_CACERT=/vault/tls/ca.crt
    VAULT_TOKEN="$(cat /tmp/.vt)"
    export VAULT_TOKEN
    vault status >/dev/null
    vault operator raft snapshot save /dev/stdout
  ' >"$snapshot_tmp" || exit 1

  [[ -s "$snapshot_tmp" ]] || { echo 'Vault Raft snapshot is empty' >&2; exit 1; }
  docker exec -i "$VAULT_CONTAINER" sh -ceu '
    vault operator raft snapshot inspect /dev/stdin
  ' <"$snapshot_tmp" >"$inspect_tmp" || exit 1
  [[ -s "$inspect_tmp" ]] || { echo 'Vault Raft snapshot inspect report is empty' >&2; exit 1; }
  chmod 600 "$snapshot_tmp" "$inspect_tmp" || exit 1
  mv "$snapshot_tmp" "${destination}/vault.snap" || exit 1
  mv "$inspect_tmp" "${destination}/inspect.txt" || exit 1

  (
    cd "$destination"
    sha256sum vault.snap >"$(basename "$checksum_tmp")"
    sha256sum -c "$(basename "$checksum_tmp")" >/dev/null
  ) || exit 1
  chmod 600 "$checksum_tmp" || exit 1
  mv "$checksum_tmp" "${destination}/SHA256SUMS" || exit 1

  docker exec "$VAULT_CONTAINER" sh -ceu '
    export VAULT_ADDR=https://127.0.0.1:8200
    export VAULT_CACERT=/vault/tls/ca.crt
    VAULT_TOKEN="$(cat /tmp/.vt)"
    export VAULT_TOKEN
    vault read -field=certificate pki_int/cert/ca
  ' >"$ca_tmp" || exit 1
  chmod 600 "$ca_tmp" || exit 1
  not_after="$(openssl x509 -in "$ca_tmp" -noout -enddate | cut -d= -f2-)" || exit 1
  [[ -n "$not_after" ]] || { echo 'Vault Intermediate expiration is missing' >&2; exit 1; }
  intermediate_expiry="$(date -u -d "$not_after" +%s)" || exit 1
  [[ "$intermediate_expiry" =~ ^[0-9]+$ ]] || {
    echo 'Vault Intermediate expiration is invalid' >&2
    exit 1
  }
  rm -f "$ca_tmp" || exit 1

  chmod 600 "${destination}/vault.snap" "${destination}/inspect.txt" "${destination}/SHA256SUMS" || exit 1

  install -d -m 755 "$NODE_EXPORTER_TEXTFILE" || exit 1
  metric_tmp="$(mktemp "${NODE_EXPORTER_TEXTFILE}/.vault-raft.prom.XXXXXX")" || exit 1
  {
    printf 'vault_raft_snapshot_last_success_timestamp_seconds %s\n' "$(date +%s)"
    printf 'vault_pki_intermediate_expiration_timestamp_seconds %s\n' "$intermediate_expiry"
  } >"$metric_tmp" || exit 1
  chmod 644 "$metric_tmp" || exit 1
  mv "$metric_tmp" "${NODE_EXPORTER_TEXTFILE}/vault-raft.prom" || exit 1
  metric_tmp=''

  complete=1
)

main() {
  local stamp postgres_dir storage_dir config_dir k3d_dir vault_dir

  acquire_backup_lock || exit 1

  stamp="$(TZ=Asia/Seoul date +%Y%m%dT%H%M%SKST)"
  postgres_dir="${BACKUP_ROOT}/supabase/postgres/${stamp}"
  storage_dir="${BACKUP_ROOT}/supabase/storage/${stamp}"
  config_dir="${BACKUP_ROOT}/mgmt-config/${stamp}"
  k3d_dir="${BACKUP_ROOT}/k3d-mgmt-datastore/${stamp}"
  vault_dir="${BACKUP_ROOT}/vault-raft/${stamp}"

  mkdir -p "$postgres_dir" "$storage_dir" "$config_dir" "$k3d_dir"
  chmod 700 "$postgres_dir" "$storage_dir" "$config_dir" "$k3d_dir"

  require_container supabase-db
  require_container minio
  require_container "$VAULT_CONTAINER"

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
  create_config_backup "${config_dir}/mgmt-config.tar.gz"
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

  echo "[$(date -Is)] backing up Vault Raft"
  create_vault_raft_snapshot "$vault_dir"

  find "$postgres_dir" "$storage_dir" "$config_dir" "$k3d_dir" "$vault_dir" -type f -exec chmod 600 {} +

  echo "[$(date -Is)] uploading backups to MinIO ${MINIO_BUCKET}"
  MINIO_ROOT_USER="$(get_env_value "$MINIO_ENV" MINIO_ROOT_USER)"
  ADMIN_PASSWORD="$(get_env_value "$MINIO_ENV" ADMIN_PASSWORD)"

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
      mc cp --recursive /backups/vault-raft/${stamp}/ local/${MINIO_BUCKET}/vault-raft/daily/${stamp}/
    "

  echo "[$(date -Is)] backup completed: ${stamp}"
}

if [[ "${MGMT_DB_BACKUP_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
