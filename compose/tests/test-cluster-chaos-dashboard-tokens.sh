#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
vault_agent="$ROOT_DIR/compose/stacks/security/vault-agent/config/agent.hcl"
issuer="$ROOT_DIR/compose/scripts/issue-cluster-chaos-dashboard-token.sh"
provisioner="$ROOT_DIR/compose/scripts/provision-cluster-chaos-dashboard-templates.sh"
bootstrap="$ROOT_DIR/compose/scripts/bootstrap-vault-cluster-chaos-dashboard-issuers.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }
assert_not_contains() { ! grep -Fq -- "$2" "$1" || fail "did not expect '$2' in $1"; }

for team in nmg ggg khb ljw oje; do
  assert_contains "$vault_agent" "kv/data/mgmt/chaos/dashboard-token-issuers/$team"
  assert_contains "$vault_agent" "destination = \"/vault/secrets/cicd/chaos-dashboard-token-issuers/$team.env\""
  assert_contains "$provisioner" "chaos-dashboard-token-issuers/$team.env"
  assert_contains "$bootstrap" 'mgmt/argocd/clusters/$cluster'
  assert_contains "$bootstrap" 'mgmt/chaos/dashboard-token-issuers/$cluster'
done

assert_contains "$issuer" 'case "$CHAOS_DASHBOARD_CLUSTER" in'
assert_contains "$issuer" 'mgmt|nmg|ggg|khb|ljw|oje)'
assert_contains "$issuer" 'create token chaos-dashboard-manager --duration=10m'
assert_contains "$issuer" 'serviceaccounts/chaos-dashboard-manager'
assert_not_contains "$issuer" 'ssh '
assert_not_contains "$issuer" 'cluster-admin'
assert_contains "$provisioner" 'Dashboard token issuer - '
assert_contains "$provisioner" 'CHAOS_DASHBOARD_CLUSTER'
assert_contains "$bootstrap" 'vault kv put -mount=kv'
assert_not_contains "$bootstrap" 'cluster-admin'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/kubectl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${KUBECTL_LOG:?}"
if [[ "$*" == *' auth can-i '* ]]; then exit 0; fi
if [[ "$*" == *' create token '* ]]; then printf 'test-dashboard-token\n'; exit 0; fi
exit 1
SH
chmod +x "$tmp/bin/kubectl"
PATH="$tmp/bin:$PATH" KUBECTL_LOG="$tmp/kubectl.log" \
  CHAOS_DASHBOARD_CLUSTER=nmg \
  CHAOS_TOKEN_ISSUER_KUBECONFIG_B64="$(printf 'test-kubeconfig' | base64 | tr -d '\n')" \
  "$issuer" >"$tmp/output"
assert_contains "$tmp/output" 'test-dashboard-token'
assert_contains "$tmp/kubectl.log" '-n chaos-mesh auth can-i create serviceaccounts/chaos-dashboard-manager --subresource=token --quiet'
assert_contains "$tmp/kubectl.log" '-n chaos-mesh create token chaos-dashboard-manager --duration=10m'

echo 'CLUSTER_CHAOS_DASHBOARD_TOKEN_VALIDATION=PASS'
