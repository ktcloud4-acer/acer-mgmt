#!/usr/bin/env bash
set -euo pipefail

MGMT_ENV=${MGMT_ENV:-/home/user1/acer-mgmt/.env}
AWS_ENV=${AWS_ENV:-/etc/acer-backup/aws-s3.env}
MINIO_MC_IMAGE=${MINIO_MC_IMAGE:-quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z}
MINIO_NETWORK=${MINIO_NETWORK:-minio_default}
MINIO_ALIAS_URL=${MINIO_ALIAS_URL:-http://minio:9000}

get_env_value() {
  local file="$1"
  local key="$2"
  local value
  value="$(grep -m1 "^${key}=" "$file" | cut -d= -f2- || true)"
  if [[ -z "$value" ]]; then
    echo "Missing ${key} in ${file}" >&2
    exit 1
  fi
  printf '%s' "$value"
}

if [[ ! -f "$AWS_ENV" ]]; then
  echo "Missing AWS credential file: ${AWS_ENV}" >&2
  exit 1
fi

AWS_ACCESS_KEY_ID="$(get_env_value "$AWS_ENV" AWS_ACCESS_KEY_ID)"
AWS_SECRET_ACCESS_KEY="$(get_env_value "$AWS_ENV" AWS_SECRET_ACCESS_KEY)"
AWS_REGION="$(get_env_value "$AWS_ENV" AWS_REGION)"
AWS_S3_BUCKET="$(get_env_value "$AWS_ENV" AWS_S3_BUCKET)"
MINIO_ROOT_USER="$(get_env_value "$MGMT_ENV" MINIO_ROOT_USER)"
ADMIN_PASSWORD="$(get_env_value "$MGMT_ENV" ADMIN_PASSWORD)"

echo "[$(date -Is)] mirroring MinIO backup buckets to AWS S3 bucket ${AWS_S3_BUCKET}"

docker run --rm --network "$MINIO_NETWORK" \
  -e MINIO_ROOT_USER="$MINIO_ROOT_USER" \
  -e ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  -e AWS_REGION="$AWS_REGION" \
  -e AWS_S3_BUCKET="$AWS_S3_BUCKET" \
  -e MINIO_ALIAS_URL="$MINIO_ALIAS_URL" \
  --entrypoint /bin/sh "$MINIO_MC_IMAGE" -ec '
    mc alias set local "$MINIO_ALIAS_URL" "$MINIO_ROOT_USER" "$ADMIN_PASSWORD" >/dev/null
    mc alias set aws "https://s3.${AWS_REGION}.amazonaws.com" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" >/dev/null

    mc mirror local/db-backup "aws/${AWS_S3_BUCKET}/db-backup"
    mc mirror local/etcd "aws/${AWS_S3_BUCKET}/etcd"
    mc mirror local/velero "aws/${AWS_S3_BUCKET}/velero"

    restic_attempt=1
    while [ "$restic_attempt" -le 3 ]; do
      if mc mirror local/restic "aws/${AWS_S3_BUCKET}/restic"; then
        exit 0
      fi
      echo "restic mirror attempt ${restic_attempt} failed; retrying" >&2
      restic_attempt=$((restic_attempt + 1))
      sleep 30
    done
    echo "restic mirror failed after 3 attempts" >&2
    exit 1
  '

echo "[$(date -Is)] AWS S3 offsite mirror completed"
