#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
runbook="$root/docs/runbooks/vault-pki-operations.md"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
require() { grep -Fq -- "$1" "$runbook" || fail "runbook missing: $1"; }
forbid() { if grep -Eq -- "$1" "$runbook"; then fail "runbook contains forbidden pattern: $1"; fi; }

for expected in \
  'SOURCE_SNAPSHOT_DIR=' \
  '(cd "$SOURCE_SNAPSHOT_DIR" && sha256sum -c SHA256SUMS)' \
  'cp -- "$SOURCE_SNAPSHOT_DIR/vault.snap" "$SOURCE_SNAPSHOT_DIR/SHA256SUMS" "$VERIFIED_DIR/"' \
  '(cd "$VERIFIED_DIR" && sha256sum -c SHA256SUMS)' \
  'RUN_ID="$(openssl rand -hex 12)"' \
  '[[ "$RUN_ID" =~ ^[0-9a-f]{24}$ ]]' \
  'DRILL_CONTAINER="vault-restore-${RUN_ID}"' \
  'DRILL_NETWORK="vault-restore-net-${RUN_ID}"' \
  'DRILL_VOLUME="vault-restore-data-${RUN_ID}"' \
  'docker container inspect "$DRILL_CONTAINER"' \
  'docker network inspect "$DRILL_NETWORK"' \
  'docker volume inspect "$DRILL_VOLUME"' \
  'NETWORK_CREATED=1' \
  'VOLUME_CREATED=1' \
  'CONTAINER_CREATED=1' \
  '[[ "$CONTAINER_CREATED" == 1 ]]' \
  '[[ "$VOLUME_CREATED" == 1 ]]' \
  '[[ "$NETWORK_CREATED" == 1 ]]' \
  '-v "$VERIFIED_DIR:/vault/restore:ro"' \
  'vault operator raft snapshot restore -force /vault/restore/vault.snap' \
  'docker image inspect "$VAULT_IMAGE"' \
  'vault version' \
  'prom/prometheus@sha256:69f5241418838263316593f7274a304b095c40bcf22e57272865da91bd60a8ac'; do
  require "$expected"
done
forbid 'docker cp .*vault\.snap'
forbid '/tmp/vault\.snap'

# A substituted/corrupt source snapshot must fail against the original manifest.
mkdir "$tmp/source"
printf 'original-snapshot' >"$tmp/source/vault.snap"
(cd "$tmp/source" && sha256sum vault.snap >SHA256SUMS)
printf 'tampered-snapshot' >"$tmp/source/vault.snap"
if (cd "$tmp/source" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then
  fail 'checksum mismatch was accepted'
fi

# Model the runbook's created-flag cleanup at every failure boundary. Pre-existing
# resources are deliberately separate and must never be removed.
simulate_failure() {
  local failure_stage="$1" state
  state="$tmp/state-$failure_stage"
  local run_id='0123456789abcdef01234567'
  local network="vault-restore-net-${run_id}"
  local volume="vault-restore-data-${run_id}"
  local container="vault-restore-${run_id}"
  local network_created=0 volume_created=0 container_created=0
  mkdir "$state"
  touch "$state/network-preexisting" "$state/volume-preexisting" "$state/container-preexisting"

  cleanup_model() {
    if [[ "$container_created" == 1 ]]; then rm -f "$state/container-$container"; fi
    if [[ "$volume_created" == 1 ]]; then rm -f "$state/volume-$volume"; fi
    if [[ "$network_created" == 1 ]]; then rm -f "$state/network-$network"; fi
  }
  if [[ "$failure_stage" != before_network ]]; then
    touch "$state/network-$network"; network_created=1
  fi
  if [[ "$failure_stage" != before_network && "$failure_stage" != after_network ]]; then
    touch "$state/volume-$volume"; volume_created=1
  fi
  if [[ "$failure_stage" == after_container ]]; then
    touch "$state/container-$container"; container_created=1
  fi
  cleanup_model

  for kind in network volume container; do
    [[ -e "$state/${kind}-preexisting" ]] || fail "$kind pre-existing resource was deleted at $failure_stage"
  done
  if find "$state" -name "*-$run_id" -print -quit | grep -q .; then
    fail "owned resource leaked at $failure_stage"
  fi
}
for stage in before_network after_network after_volume after_container; do
  simulate_failure "$stage"
done

echo 'VAULT_PKI_RESTORE_MODEL=PASS'
