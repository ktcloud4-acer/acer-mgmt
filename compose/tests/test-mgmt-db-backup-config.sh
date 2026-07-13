#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCRIPT="${REPO_ROOT}/compose/scripts/mgmt-db-backup.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_absent() {
  [[ ! -e "$1" ]] || fail "unexpected file: $1"
}

assert_no_transients() {
  local destination="$1"
  assert_file_absent "${destination}/intermediate-ca.pem"
  if find "$destination" "$NODE_EXPORTER_TEXTFILE" -maxdepth 1 -type f \
      \( -name '*.tmp' -o -name 'vault-raft.prom.*' -o -name '*intermediate-ca*' \) \
      -print -quit 2>/dev/null | grep -q .; then
    fail "transient host file remained after snapshot attempt"
  fi
}

home_root="${tmpdir}/home/user1"
mkdir -p \
  "${home_root}/acer-mgmt/compose" \
  "${home_root}/acer-mgmt/secrets" \
  "${home_root}/acer-mgmt/k3d"
touch "${home_root}/acer-mgmt/.env"
printf 'snapshot' >"${home_root}/acer-mgmt/compose/vault.snap"
printf 'token' >"${home_root}/acer-mgmt/secrets/.vt"
printf 'certificate' >"${home_root}/acer-mgmt/compose/intermediate-ca.pem"

DATA_ROOT="${tmpdir}/data"
BACKUP_ROOT="${tmpdir}/backups"
MGMT_DB_BACKUP_SOURCE_ONLY=1 source "${SCRIPT}"

[[ "$VAULT_CONTAINER" == vault ]] || fail "unsafe VAULT_CONTAINER default: $VAULT_CONTAINER"
[[ "$NODE_EXPORTER_TEXTFILE" == "${DATA_ROOT}/node-exporter-textfile" ]] || \
  fail "unexpected NODE_EXPORTER_TEXTFILE default: $NODE_EXPORTER_TEXTFILE"
[[ "$BACKUP_LOCK_FILE" == "${DATA_ROOT}/locks/mgmt-db-backup.lock" ]] || \
  fail "unexpected BACKUP_LOCK_FILE default: $BACKUP_LOCK_FILE"
[[ "$BACKUP_FLOCK_BIN" == flock ]] || fail "unexpected BACKUP_FLOCK_BIN default: $BACKUP_FLOCK_BIN"
declare -F acquire_backup_lock >/dev/null || fail "missing acquire_backup_lock"
declare -F create_vault_raft_snapshot >/dev/null || fail "missing create_vault_raft_snapshot"

archive_without_argocd="${tmpdir}/without-argocd.tar.gz"
create_config_backup "${archive_without_argocd}" "${home_root}"

tar_listing="$(tar -tzf "${archive_without_argocd}")"
grep -qx 'acer-mgmt/.env' <<<"$tar_listing" || fail "missing acer-mgmt/.env in config backup"
if grep -q '^acer-argocd' <<<"$tar_listing"; then
  fail "acer-argocd should not be included when the checkout is absent"
fi
if grep -Eq '(^|/)(vault\.snap|\.vt|intermediate-ca\.pem)$' <<<"$tar_listing"; then
  fail "config archive contains Vault snapshot, token, or transient CA material"
fi

mkdir -p "${home_root}/acer-argocd"
touch "${home_root}/acer-argocd/application.yaml"

archive_with_argocd="${tmpdir}/with-argocd.tar.gz"
create_config_backup "${archive_with_argocd}" "${home_root}"

tar -tzf "${archive_with_argocd}" | grep -qx 'acer-argocd/application.yaml' || \
  fail "missing optional acer-argocd checkout in config backup"

flock_state="${tmpdir}/flock-state"
flock_shim="${tmpdir}/flock-shim"
cat >"$flock_shim" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -n && "${2:-}" =~ ^[0-9]+$ ]] || exit 64
mkdir "$FLOCK_TEST_STATE"
SH
chmod +x "$flock_shim"
export FLOCK_TEST_STATE="$flock_state"

lock_root="${tmpdir}/lock-overlap"
mkdir -p "$lock_root"
mkfifo "${lock_root}/release"
owner_artifact="${lock_root}/owner.snapshot"
ready_file="${lock_root}/ready"
(
  DATA_ROOT="$DATA_ROOT"
  BACKUP_LOCK_FILE="${lock_root}/backup.lock"
  BACKUP_FLOCK_BIN="$flock_shim"
  MGMT_DB_BACKUP_SOURCE_ONLY=1 source "$SCRIPT"
  acquire_backup_lock || exit 1
  printf 'owner-snapshot' >"$owner_artifact"
  : >"$ready_file"
  read -r _ <"${lock_root}/release" || true
) &
lock_owner_pid=$!
for _ in {1..100}; do
  [[ -e "$ready_file" ]] && break
  sleep 0.02
done
[[ -e "$ready_file" ]] || fail "first lock owner did not become ready"

lock_refusal_start="$(date +%s)"
if (
  DATA_ROOT="$DATA_ROOT"
  BACKUP_LOCK_FILE="${lock_root}/backup.lock"
  BACKUP_FLOCK_BIN="$flock_shim"
  MGMT_DB_BACKUP_SOURCE_ONLY=1 source "$SCRIPT"
  acquire_backup_lock || exit 1
  printf 'cross-copied-snapshot' >"$owner_artifact"
) >"${lock_root}/refusal.out" 2>"${lock_root}/refusal.err"; then
  fail "second overlapping backup acquired the lock"
fi
(( $(date +%s) - lock_refusal_start < 2 )) || fail "overlapping backup did not fail fast"
grep -qx 'owner-snapshot' "$owner_artifact" || fail "lock refuser altered another invocation artifact"
grep -Fq 'Another mgmt backup is already running' "${lock_root}/refusal.err" || \
  fail "lock refusal error is not explicit"
printf 'release\n' >"${lock_root}/release"
wait "$lock_owner_pid"
rm -rf "$flock_state"

mkdir "$flock_state"
locked_main_root="${tmpdir}/locked-main-backups"
docker_called="${tmpdir}/locked-main-docker-called"
docker() { : >"$docker_called"; return 1; }
if (
  BACKUP_ROOT="$locked_main_root"
  BACKUP_LOCK_FILE="${lock_root}/backup.lock"
  BACKUP_FLOCK_BIN="$flock_shim"
  main
) >"${lock_root}/main-refusal.out" 2>"${lock_root}/main-refusal.err"; then
  fail "locked main backup unexpectedly continued"
fi
assert_file_absent "$docker_called"
assert_file_absent "$locked_main_root"
rm -rf "$flock_state"
unset -f docker

BACKUP_FLOCK_BIN="${tmpdir}/missing-flock"
if acquire_backup_lock >"${tmpdir}/missing-flock.out" 2>"${tmpdir}/missing-flock.err"; then
  fail "missing flock implementation was accepted"
fi
grep -Fq 'Required lock command not found' "${tmpdir}/missing-flock.err" || \
  fail "missing flock error is not explicit"
BACKUP_FLOCK_BIN=flock

mkdir -p "$NODE_EXPORTER_TEXTFILE"
test_ca="${tmpdir}/test-ca.pem"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj '//CN=Task 4 Test CA' \
  -keyout "${tmpdir}/test-ca.key" -out "$test_ca" >/dev/null 2>&1
expected_expiry="$(date -u -d "$(openssl x509 -in "$test_ca" -noout -enddate | cut -d= -f2-)" +%s)"

snapshot_scenario=success
docker_events="${tmpdir}/docker.events"
metric_publish_events="${tmpdir}/metric-publish.events"
metric_mode_events="${tmpdir}/metric-mode.events"
snapshot_fixture_size=$((17 * 1024 * 1024))
inspect_input_size=''

docker() {
  printf '%q ' "$@" >>"$docker_events"
  printf '\n' >>"$docker_events"

  case "$1" in
    inspect)
      return 0
      ;;
    exec)
      shift
      local interactive=0
      if [[ "${1:-}" == -i ]]; then
        interactive=1
        shift
      fi
      [[ "$1" == vault ]] || fail "unexpected container: $1"
      shift
      if [[ "$1" == sh && "${*: -1}" == *'vault operator raft snapshot save'* ]]; then
        local inner_script="${*: -1}"
        [[ "$interactive" == 0 ]] || fail "snapshot save unexpectedly used stdin"
        [[ "$inner_script" == *'vault status'*'vault operator raft snapshot save /dev/stdout'* ]] || \
          fail "Vault status is not enforced before streamed snapshot save"
        [[ "$inner_script" != *'/tmp/acer-vault-raft'* ]] || fail "snapshot uses container tmpfs"
        [[ "$snapshot_scenario" != unhealthy ]] || return 2
        [[ "$snapshot_scenario" != snapshot_fail ]] || return 1
        if [[ "$snapshot_scenario" == stream_fail ]]; then
          head -c 4096 /dev/zero
          return 1
        fi
        if [[ "$snapshot_scenario" == success ]]; then
          head -c "$snapshot_fixture_size" /dev/zero
        else
          head -c 65536 /dev/zero
        fi
        return 0
      fi
      if [[ "$1" == sh && "${*: -1}" == *'vault operator raft snapshot inspect'* ]]; then
        [[ "$interactive" == 1 ]] || fail "snapshot inspect did not stream stdin"
        [[ "${*: -1}" == *'vault operator raft snapshot inspect /dev/stdin'* ]] || \
          fail "snapshot inspect did not consume /dev/stdin"
        inspect_input_size="$(wc -c)"
        [[ "$snapshot_scenario" != inspect_fail ]] || return 1
        printf 'Snapshot ID: task-4-test\nSize: %s\n' "$inspect_input_size"
        return 0
      fi
      if [[ "$1" == sh && "${*: -1}" == *'pki_int/cert/ca'* ]]; then
        [[ "$snapshot_scenario" != ca_fail ]] || return 1
        cat "$test_ca"
        return 0
      fi
      fail "unexpected docker exec: $*"
      ;;
    cp)
      fail "snapshot must not use docker cp or container files"
      ;;
    *)
      fail "unexpected docker command: $*"
      ;;
  esac
}

sha256sum() {
  [[ "$snapshot_scenario" != checksum_fail ]] || return 1
  command sha256sum "$@"
}

chmod() {
  if [[ "$snapshot_scenario" == mode_fail && "${1:-}" == 600 && "${2:-}" == */vault.snap ]]; then
    return 1
  fi
  if [[ "${1:-}" == 644 && "${2:-}" == "${NODE_EXPORTER_TEXTFILE}/"* ]]; then
    printf '%s\n' "$2" >>"$metric_mode_events"
  fi
  command chmod "$@"
}

mv() {
  if [[ "${*: -1}" == "${NODE_EXPORTER_TEXTFILE}/vault-raft.prom" ]]; then
    grep -qx 'old-snapshot-success 1' "${NODE_EXPORTER_TEXTFILE}/vault-raft.prom" || \
      fail "old metric was altered before atomic publish"
    grep -Fxq "$1" "$metric_mode_events" || fail "metric temp was not chmodded to 644"
    printf 'publish\n' >>"$metric_publish_events"
  fi
  command mv "$@"
}

existing_dir="${BACKUP_ROOT}/vault-raft/existing"
mkdir -p "$existing_dir"
printf 'preserve-me' >"${existing_dir}/sentinel"
printf 'preserve-existing-temp-name' >"${existing_dir}/vault.snap.tmp"
if create_vault_raft_snapshot "$existing_dir" >"${tmpdir}/existing.out" 2>"${tmpdir}/existing.err"; then
  fail "snapshot unexpectedly replaced an existing destination"
fi
grep -qx 'preserve-me' "${existing_dir}/sentinel" || fail "existing destination was deleted on refusal"
grep -qx 'preserve-existing-temp-name' "${existing_dir}/vault.snap.tmp" || \
  fail "existing destination content was altered on refusal"

success_dir="${BACKUP_ROOT}/vault-raft/20260713T120000KST"
success_output="${tmpdir}/snapshot.stdout"
printf 'old-snapshot-success 1\n' >"${NODE_EXPORTER_TEXTFILE}/vault-raft.prom"
create_vault_raft_snapshot "$success_dir" >"$success_output"

[[ -s "${success_dir}/vault.snap" ]] || fail "missing snapshot"
[[ -s "${success_dir}/inspect.txt" ]] || fail "missing inspect report"
[[ "$(wc -c <"${success_dir}/vault.snap")" -eq "$snapshot_fixture_size" ]] || \
  fail "streamed snapshot did not preserve the >16 MiB fixture"
grep -qx "Size: ${snapshot_fixture_size}" "${success_dir}/inspect.txt" || \
  fail "inspect did not consume the exact streamed host snapshot"
(cd "$success_dir" && command sha256sum -c SHA256SUMS >/dev/null) || fail "snapshot checksum is not portable"
[[ "$(stat -c '%a' "$success_dir")" == 700 ]] || fail "snapshot directory is not private"
while IFS= read -r artifact; do
  [[ "$(stat -c '%a' "$artifact")" == 600 ]] || fail "artifact is not mode 600: $artifact"
done < <(find "$success_dir" -maxdepth 1 -type f -print)
metric="${NODE_EXPORTER_TEXTFILE}/vault-raft.prom"
if [[ "$(uname -s)" != MINGW* ]]; then
  [[ "$(stat -c '%a' "$metric")" == 644 ]] || fail "final metric is not mode 644"
fi
grep -Eq '^vault_raft_snapshot_last_success_timestamp_seconds [0-9]+$' "$metric" || \
  fail "missing snapshot success metric"
grep -qx "vault_pki_intermediate_expiration_timestamp_seconds ${expected_expiry}" "$metric" || \
  fail "wrong Intermediate expiry metric"
[[ "$(wc -l <"$metric_publish_events")" -eq 1 ]] || fail "metric was not published atomically once"
assert_no_transients "$success_dir"
if grep -Fq 'task-4-vault-token' "$success_output"; then
  fail "Vault token leaked to output"
fi

for snapshot_scenario in unhealthy snapshot_fail stream_fail inspect_fail checksum_fail ca_fail mode_fail; do
  failure_root="${tmpdir}/failure-${snapshot_scenario}"
  failure_node="${failure_root}/node-exporter"
  failure_dir="${failure_root}/vault-raft/stamp"
  NODE_EXPORTER_TEXTFILE="$failure_node"
  mkdir -p "$failure_node"
  if [[ "$snapshot_scenario" == ca_fail ]]; then
    printf 'old-snapshot-success 1\n' >"${failure_node}/vault-raft.prom"
  fi
  if create_vault_raft_snapshot "$failure_dir" >"${failure_root}.out" 2>"${failure_root}.err"; then
    fail "snapshot scenario unexpectedly succeeded: $snapshot_scenario"
  fi
  if [[ "$snapshot_scenario" == ca_fail ]]; then
    grep -qx 'old-snapshot-success 1' "${failure_node}/vault-raft.prom" || \
      fail "failed attempt advanced or removed the previous success metric"
  else
    assert_file_absent "${failure_node}/vault-raft.prom"
  fi
  assert_no_transients "$failure_dir"
done

script_text="$(<"$SCRIPT")"
grep -Fq 'vault operator raft snapshot save' <<<"$script_text" || fail "missing snapshot save command"
grep -Fq 'vault operator raft snapshot inspect' <<<"$script_text" || fail "missing snapshot inspect command"
grep -Fq 'vault operator raft snapshot save /dev/stdout' <<<"$script_text" || \
  fail "snapshot is not streamed to the host"
grep -Fq 'vault operator raft snapshot inspect /dev/stdin' <<<"$script_text" || \
  fail "inspect is not streamed from the host snapshot"
if grep -Eq '/tmp/acer-vault-raft|docker cp.*vault' <<<"$script_text"; then
  fail "snapshot still depends on shared container temporary storage"
fi
grep -Fq 'mc cp --recursive /backups/vault-raft/${stamp}/ local/${MINIO_BUCKET}/vault-raft/daily/${stamp}/' \
  <<<"$script_text" || fail "missing exact MinIO Vault daily path"
if grep -Eq 'set[[:space:]]+-[^[:space:]]*x|VAULT_TOKEN=.*echo|echo.*VAULT_TOKEN' <<<"$script_text"; then
  fail "backup script may print the Vault token"
fi

echo 'MGMT_DB_BACKUP_CONFIG=PASS'
