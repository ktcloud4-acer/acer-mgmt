#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RULES="${REPO_ROOT}/compose/stacks/observability/prometheus/config/alerts/infra-pki.yml"
PROMETHEUS_CONFIG="${REPO_ROOT}/compose/stacks/observability/prometheus/config/prometheus.yml"
RUNBOOK="${REPO_ROOT}/docs/runbooks/vault-pki-operations.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

assert_contains() {
  local file="$1" expected="$2"
  grep -Fq -- "$expected" "$file" || fail "expected '${expected}' in ${file}"
}

alert_block() {
  local alert="$1"
  awk -v alert="$alert" '
    /^      - alert: / {
      if (printing) exit
      printing = ($3 == alert)
    }
    printing { print }
  ' "$RULES"
}

assert_alert_once() {
  local alert="$1" count
  count="$(grep -Ec "^      - alert: ${alert}$" "$RULES")"
  [[ "$count" == 1 ]] || fail "alert ${alert} must occur exactly once (found ${count})"
}

assert_alert_contains() {
  local alert="$1" expected="$2" block
  block="$(alert_block "$alert")"
  [[ -n "$block" ]] || fail "missing alert: ${alert}"
  grep -Fq -- "$expected" <<<"$block" || fail "alert ${alert} must contain: ${expected}"
}

assert_file "$RULES"
assert_file "$PROMETHEUS_CONFIG"
assert_file "$RUNBOOK"

assert_contains "$PROMETHEUS_CONFIG" '/etc/prometheus/alerts/*.yml'
assert_contains "$PROMETHEUS_CONFIG" 'https://vault.imcherry5778.xyz/v1/sys/health?standbyok=true&perfstandbyok=true'

alerts=(
  VaultRaftSnapshotStale
  VaultIntermediateExpiresWithin180Days
  CertificateExpiresWithin30Days
  CertificateExpiresWithin14Days
  CertificateExpiresWithin7Days
  CertificateNotReady
  ClusterIssuerNotReady
  CertManagerVaultSyncErrors
)
for alert in "${alerts[@]}"; do
  assert_alert_once "$alert"
  assert_alert_contains "$alert" 'team: platform'
  assert_alert_contains "$alert" 'channel: infra'
  assert_alert_contains "$alert" 'runbook: "docs/runbooks/vault-pki-operations.md"'
  assert_alert_contains "$alert" 'title:'
  assert_alert_contains "$alert" 'summary:'
  assert_alert_contains "$alert" 'description:'
done
assert_alert_contains VaultRaftSnapshotStale 'scope: backup'
for alert in "${alerts[@]:1}"; do
  assert_alert_contains "$alert" 'scope: pki'
done

assert_alert_contains VaultRaftSnapshotStale 'absent(vault_raft_snapshot_last_success_timestamp_seconds{job="mgmt-node"})'
assert_alert_contains VaultRaftSnapshotStale 'time() - vault_raft_snapshot_last_success_timestamp_seconds{job="mgmt-node"} > 93600'
assert_alert_contains VaultRaftSnapshotStale 'for: 30m'
assert_alert_contains VaultRaftSnapshotStale 'severity: critical'

assert_alert_contains VaultIntermediateExpiresWithin180Days 'absent(vault_pki_intermediate_expiration_timestamp_seconds{job="mgmt-node"})'
assert_alert_contains VaultIntermediateExpiresWithin180Days 'vault_pki_intermediate_expiration_timestamp_seconds{job="mgmt-node"} - time() < 15552000'
assert_alert_contains VaultIntermediateExpiresWithin180Days '이미 만료된 Intermediate도 의도적으로 이 경보를 유지합니다.'
assert_alert_contains VaultIntermediateExpiresWithin180Days 'for: 1h'
assert_alert_contains VaultIntermediateExpiresWithin180Days 'severity: warning'

# Leaf tiers are deliberately non-overlapping and ignore already expired samples.
assert_alert_contains CertificateExpiresWithin30Days 'certmanager_certificate_expiration_timestamp_seconds - time() >= 1209600'
assert_alert_contains CertificateExpiresWithin30Days 'certmanager_certificate_expiration_timestamp_seconds - time() < 2592000'
assert_alert_contains CertificateExpiresWithin14Days 'certmanager_certificate_expiration_timestamp_seconds - time() >= 604800'
assert_alert_contains CertificateExpiresWithin14Days 'certmanager_certificate_expiration_timestamp_seconds - time() < 1209600'
assert_alert_contains CertificateExpiresWithin7Days 'certmanager_certificate_expiration_timestamp_seconds - time() > 0'
assert_alert_contains CertificateExpiresWithin7Days 'certmanager_certificate_expiration_timestamp_seconds - time() < 604800'
for alert in CertificateExpiresWithin30Days CertificateExpiresWithin14Days CertificateExpiresWithin7Days; do
  assert_alert_contains "$alert" 'for: 15m'
done

assert_alert_contains CertificateNotReady 'certmanager_certificate_ready_status{condition="True"} == 0'
assert_alert_contains CertificateNotReady 'for: 15m'
assert_alert_contains ClusterIssuerNotReady 'certmanager_clusterissuer_ready_status{name="vault-internal",condition="True"} == 0'
assert_alert_contains ClusterIssuerNotReady 'for: 15m'
assert_alert_contains CertManagerVaultSyncErrors 'increase(certmanager_controller_sync_error_count{controller=~"certificates-.*|certificaterequests-issuer-vault"}[15m]) > 0'
assert_alert_contains CertManagerVaultSyncErrors 'for: 5m'

# Alert labels must stay low-cardinality and must never carry certificate subjects or Secret data.
if awk '
  /^        labels:/ { in_labels=1; next }
  /^        annotations:/ { in_labels=0 }
  in_labels && /^[[:space:]]+[A-Za-z0-9_-]+:/ { print }
' "$RULES" | grep -Eqi '(^|[[:space:]_])(subject|common_name|dns_name|secret|secret_name|certificate_pem|private_key)[[:space:]_-]*:'; then
  fail 'sensitive or high-cardinality certificate/Secret field found in alert labels'
fi
if grep -E '^        expr:.*(subject|common_name|secret_data|private_key)' "$RULES" >/dev/null; then
  fail 'alert expression exposes certificate subject or Secret data'
fi

# Runbook operational gates and copy/paste-safe workflows.
runbook_contract=(
  'Vaultwarden은 이 비프로덕션 환경에서 수용한 트레이드오프이며 HSM이 아니다.'
  'root-ca.key'
  'root-ca.crt'
  'Root CA passphrase'
  'SHA-256 fingerprint'
  '두 번째 신뢰 장비'
  '복구 검증이 성공하기 전에는 원본 평문을 삭제하지 않는다.'
  'ROOT_CA_PASS_FILE'
  'openssl verify -CAfile'
  'Public-Key: (4096 bit)'
  'Public-Key: (3072 bit)'
  'Signature Algorithm: sha384WithRSAEncryption'
  'CA:TRUE, pathlen:1'
  'CA:TRUE, pathlen:0'
  'vault-pki-generate-intermediate-csr.sh'
  'sign-vault-intermediate.sh'
  'vault-pki-install-intermediate.sh'
  'bootstrap-vault-cert-manager.sh'
  'acer-mgmt-db-backup.service'
  'vault operator raft snapshot inspect'
  'hashicorp/vault:2.0.3'
  '--entrypoint vault hashicorp/vault:2.0.3'
  'docker network create --internal --label "acer.restore.run=$RUN_ID" "$DRILL_NETWORK"'
  '[ "$status" -eq 0 ] || [ "$status" -eq 2 ]'
  '프로덕션 proxy/network에 연결하지 않는다.'
  'Intermediate 만료 180일 전'
  'vault secrets enable -path=pki_int_next pki'
  'pki_int_next/intermediate/generate/internal'
  'pki_int_next/intermediate/set-signed'
  'cert-manager-${team}-next'
  'Root 만료 2년 전'
  'dual trust'
  '정상 leaf 발급과 갱신은 cert-manager가 자동 처리한다.'
  'Chaos Dashboard JWT와 PKI 인증서는 서로 무관하다.'
  'Vault sealed/unhealthy'
  'ClusterIssuerNotReady'
  'CertManagerVaultSyncErrors'
  'VaultRaftSnapshotStale'
  'SSE-S3 또는 SSE-KMS'
)
for expected in "${runbook_contract[@]}"; do
  assert_contains "$RUNBOOK" "$expected"
done
[[ "$(grep -Fc 'vault status >/dev/null' "$RUNBOOK")" -ge 2 ]] || \
  fail 'restore verification must not mix vault status text into JSON'

if grep -E '(VAULT_TOKEN|ROOT_CA_PASSPHRASE|RECOVERED_PASSPHRASE|SOURCE_UNSEAL_KEY|SOURCE_VAULT_TOKEN)=("[A-Za-z0-9+/=]{8,}|[A-Za-z0-9+/=]{8,})' "$RUNBOOK" >/dev/null; then
  fail 'runbook appears to contain an inline credential value'
fi
if grep -E -- '--(token|password|passphrase|unseal-key|root-token)(=|[[:space:]])' "$RUNBOOK" >/dev/null; then
  fail 'runbook passes sensitive material as a command-line argument'
fi

echo 'VAULT_PKI_ALERTS=PASS'
