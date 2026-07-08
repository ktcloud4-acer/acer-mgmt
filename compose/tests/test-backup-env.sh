#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HELPER="${REPO_ROOT}/compose/scripts/backup-env.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

# shellcheck source=/dev/null
source "${HELPER}"

env_file="${tmpdir}/secrets.env"
cat >"${env_file}" <<'ENV'
MINIO_ROOT_USER=minioadmin
ADMIN_PASSWORD=pass=with=equals
ENV

actual="$(get_env_value "${env_file}" ADMIN_PASSWORD)"
[[ "${actual}" == "pass=with=equals" ]] || fail "expected value with embedded equals"

missing_output="$(
  get_env_value "${env_file}" MISSING_KEY 2>&1 >/dev/null && echo "unexpected-success" || true
)"
[[ "${missing_output}" == *"Missing MISSING_KEY in ${env_file}"* ]] || fail "missing key error was not helpful"

missing_file_output="$(
  require_env_file "${tmpdir}/missing.env" "test secrets" 2>&1 >/dev/null && echo "unexpected-success" || true
)"
[[ "${missing_file_output}" == *"Missing test secrets file: ${tmpdir}/missing.env"* ]] || fail "missing file error was not helpful"

echo "backup env helper tests passed"
