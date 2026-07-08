#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" || fail "expected '${expected}' in ${file}"
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -Fq -- "$unexpected" "$file"; then
    fail "did not expect '${unexpected}' in ${file}"
  fi
}

mgmt_db="${REPO_ROOT}/compose/scripts/mgmt-db-backup.sh"
adguard="${REPO_ROOT}/compose/scripts/adguard-backup.sh"
offsite="${REPO_ROOT}/compose/scripts/minio-offsite-s3-backup.sh"
agent="${REPO_ROOT}/compose/stacks/security/vault-agent/config/agent.hcl"
restic_compose="${REPO_ROOT}/compose/stacks/backup/restic/compose.yaml"

for script in "$mgmt_db" "$adguard" "$offsite"; do
  assert_contains "$script" 'source "${SCRIPT_DIR}/backup-env.sh"'
  assert_contains "$script" 'VAULT_SECRETS_ROOT=${VAULT_SECRETS_ROOT:-/home/mgmt-data/vault-agent/secrets}'
done

assert_contains "$mgmt_db" 'MINIO_ENV=${MINIO_ENV:-${VAULT_SECRETS_ROOT}/backup-minio.env}'
assert_contains "$adguard" 'MINIO_ENV=${MINIO_ENV:-${VAULT_SECRETS_ROOT}/backup-minio.env}'
assert_contains "$offsite" 'MINIO_ENV=${MINIO_ENV:-${VAULT_SECRETS_ROOT}/backup-minio.env}'
assert_contains "$offsite" 'AWS_ENV=${AWS_ENV:-${VAULT_SECRETS_ROOT}/offsite-s3.env}'
assert_not_contains "$offsite" 'AWS_ENV=${AWS_ENV:-/etc/acer-backup/aws-s3.env}'

assert_contains "$agent" 'destination = "/vault/secrets/backup-minio.env"'
assert_contains "$agent" 'destination = "/vault/secrets/offsite-s3.env"'
assert_contains "$agent" 'RESTIC_ACCESS_KEY='
assert_contains "$agent" 'RESTIC_SECRET_KEY='

assert_contains "$restic_compose" 'RESTIC_ACCESS_KEY: ${RESTIC_ACCESS_KEY:?RESTIC_ACCESS_KEY must be set}'
assert_contains "$restic_compose" 'RESTIC_SECRET_KEY: ${RESTIC_SECRET_KEY:?RESTIC_SECRET_KEY must be set}'
assert_contains "$restic_compose" 'target="$$((target + 86400))"'
assert_not_contains "$restic_compose" 'date -d tomorrow'

echo "backup vault secret config tests passed"
