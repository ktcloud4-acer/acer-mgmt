#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/backup-env.sh"

VAULT_SECRETS_ROOT=${VAULT_SECRETS_ROOT:-/home/mgmt-data/vault-agent/secrets}
MINIO_ENV=${MINIO_ENV:-${VAULT_SECRETS_ROOT}/backup-minio.env}
AWS_ENV=${AWS_ENV:-${VAULT_SECRETS_ROOT}/offsite-s3.env}
MINIO_MC_IMAGE=${MINIO_MC_IMAGE:-quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z}
MINIO_NETWORK=${MINIO_NETWORK:-minio_default}
MINIO_ALIAS_URL=${MINIO_ALIAS_URL:-http://minio:9000}

AWS_ACCESS_KEY_ID="$(get_env_value "$AWS_ENV" AWS_ACCESS_KEY_ID)"
AWS_SECRET_ACCESS_KEY="$(get_env_value "$AWS_ENV" AWS_SECRET_ACCESS_KEY)"
AWS_REGION="$(get_env_value "$AWS_ENV" AWS_REGION)"
AWS_S3_BUCKET="$(get_env_value "$AWS_ENV" AWS_S3_BUCKET)"
MINIO_ROOT_USER="$(get_env_value "$MINIO_ENV" MINIO_ROOT_USER)"
ADMIN_PASSWORD="$(get_env_value "$MINIO_ENV" ADMIN_PASSWORD)"

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

    if ! encryption_info="$(mc encrypt info "aws/${AWS_S3_BUCKET}")"; then
      echo "Unable to verify default encryption for AWS S3 bucket ${AWS_S3_BUCKET}" >&2
      exit 1
    fi
    if printf "%s\n" "$encryption_info" | grep -Eqi "(^|[^[:alnum:]])(disabled|not[[:space:]-]+enabled)([^[:alnum:]]|$)"; then
      echo "AWS S3 bucket ${AWS_S3_BUCKET} has no verified SSE-S3 or SSE-KMS default encryption" >&2
      exit 1
    fi
    printf "%s\n" "$encryption_info" | grep -Eqi \
      "((^|[^[:alnum:]-])SSE-(S3|KMS)([^[:alnum:]-]|$).*(^|[^[:alnum:]])enabled([^[:alnum:]]|$))|((^|[^[:alnum:]])enabled([^[:alnum:]]|$).*(^|[^[:alnum:]-])SSE-(S3|KMS)([^[:alnum:]-]|$))" || {
        echo "AWS S3 bucket ${AWS_S3_BUCKET} has no verified SSE-S3 or SSE-KMS default encryption" >&2
        exit 1
      }

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
