#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCRIPT="${REPO_ROOT}/compose/scripts/minio-offsite-s3-backup.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$tmpdir/bin"
cat >"$tmpdir/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
command_text="${*: -1}"
while (($#)); do
  if [[ "$1" == -e ]]; then
    export "$2"
    shift 2
  else
    shift
  fi
done
/bin/sh -ec "$command_text"
SH
cat >"$tmpdir/bin/mc" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MC_EVENTS"
case "${1:-} ${2:-}" in
  'alias set') exit 0 ;;
  'encrypt info')
    case "${MC_ENCRYPT_MODE:-missing}" in
      missing) exit 1 ;;
      malformed) printf 'unparseable response\n' ;;
      disabled) printf 'Default encryption is disabled\n' ;;
      disabled_with_mode) printf 'SSE-S3 default encryption is disabled\n' ;;
      bare_mode) printf 'SSE-KMS\n' ;;
      lookalike) printf 'NOT-SSE-S3 and SSE-KMS-disabled\n' ;;
      sse-s3) printf "Auto encryption 'SSE-S3' is enabled\n" ;;
      sse-kms) printf "Auto encryption 'sse-kms' is enabled\n" ;;
      *) exit 64 ;;
    esac
    ;;
  'mirror '*) exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$tmpdir/bin/docker" "$tmpdir/bin/mc"

minio_env="$tmpdir/backup-minio.env"
aws_env="$tmpdir/offsite-s3.env"
cat >"$minio_env" <<'EOF'
MINIO_ROOT_USER=test-minio-user
ADMIN_PASSWORD=test-minio-password
EOF
cat >"$aws_env" <<'EOF'
AWS_ACCESS_KEY_ID=test-aws-key
AWS_SECRET_ACCESS_KEY=test-aws-secret
AWS_REGION=ap-northeast-2
AWS_S3_BUCKET=test-backup-bucket
EOF
chmod 600 "$minio_env" "$aws_env"

run_case() {
  local mode="$1" expected="$2"
  local events="$tmpdir/events-${mode}"
  : >"$events"
  set +e
  PATH="$tmpdir/bin:$PATH" \
    MINIO_ENV="$minio_env" AWS_ENV="$aws_env" MC_EVENTS="$events" MC_ENCRYPT_MODE="$mode" \
    bash "$SCRIPT" >"$tmpdir/${mode}.out" 2>"$tmpdir/${mode}.err"
  local status=$?
  set -e

  if [[ "$expected" == fail ]]; then
    [[ $status -ne 0 ]] || fail "$mode encryption preflight unexpectedly succeeded"
    if grep -q '^mirror ' "$events"; then
      fail "$mode encryption preflight allowed a mirror"
    fi
  else
    [[ $status -eq 0 ]] || fail "$mode encryption preflight failed"
    [[ "$(grep -c '^encrypt info aws/test-backup-bucket$' "$events")" -eq 1 ]] || \
      fail "$mode did not inspect the exact AWS bucket once"
    [[ "$(grep -c '^mirror ' "$events")" -eq 4 ]] || fail "$mode did not run all existing mirrors"
    local encryption_line first_mirror_line
    encryption_line="$(grep -n '^encrypt info ' "$events" | cut -d: -f1)"
    first_mirror_line="$(grep -n '^mirror ' "$events" | head -1 | cut -d: -f1)"
    ((encryption_line < first_mirror_line)) || fail "$mode encryption preflight ran after a mirror"
    grep -qx 'mirror local/db-backup aws/test-backup-bucket/db-backup' "$events" || \
      fail "$mode changed the existing whole db-backup mirror"
  fi

  if grep -Eq 'test-(aws-secret|minio-password)' "$tmpdir/${mode}.out" "$tmpdir/${mode}.err"; then
    fail "$mode leaked a credential"
  fi
}

run_case missing fail
run_case malformed fail
run_case disabled fail
run_case disabled_with_mode fail
run_case bare_mode fail
run_case lookalike fail
run_case sse-s3 pass
run_case sse-kms pass

script_text="$(<"$SCRIPT")"
if grep -Eq 'mc encrypt set|set[[:space:]]+-[^[:space:]]*x' <<<"$script_text"; then
  fail "offsite job mutates encryption or enables tracing"
fi

echo 'MINIO_OFFSITE_VAULT_ENCRYPTION=PASS'
