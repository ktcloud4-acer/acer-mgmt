#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dockerfile="${ROOT_DIR}/compose/stacks/cicd/semaphore/Dockerfile"
compose_file="${ROOT_DIR}/compose/stacks/cicd/semaphore/compose.yaml"
vault_agent="${ROOT_DIR}/compose/stacks/security/vault-agent/config/agent.hcl"
script="${ROOT_DIR}/compose/scripts/issue-chaos-dashboard-token.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }
assert_not_contains() { ! grep -Fq -- "$2" "$1" || fail "did not expect '$2' in $1"; }

assert_contains "$dockerfile" 'KUBECTL_VERSION=v1.35.6'
assert_contains "$dockerfile" 'kubectl'
assert_not_contains "$compose_file" 'chaos-dashboard-token-issuer.kubeconfig'
assert_contains "$vault_agent" 'kv/data/mgmt/chaos-dashboard-token-issuer'
assert_contains "$vault_agent" 'destination = "/vault/secrets/cicd/chaos-dashboard-token-issuer.env"'
assert_contains "$script" 'create token chaos-dashboard-manager --duration="${CHAOS_DASHBOARD_TOKEN_DURATION:-10m}"'
assert_contains "$script" 'CHAOS_DASHBOARD_TOKEN_DURATION'
assert_contains "$script" 'CHAOS_TOKEN_ISSUER_KUBECONFIG_B64'
assert_contains "$script" 'base64 -d'
assert_contains "$script" 'serviceaccounts/chaos-dashboard-manager'
assert_contains "$script" '--subresource=token'
assert_not_contains "$script" 'ssh '
assert_not_contains "$script" 'cluster-admin'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/kubectl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${KUBECTL_LOG:?}"
if [[ "$*" == *' auth can-i '* ]]; then
  exit 0
fi
if [[ "$*" == *' create token '* ]]; then
  printf 'test-dashboard-token\n'
  exit 0
fi
exit 1
SH
chmod +x "$tmp/bin/kubectl"
PATH="$tmp/bin:$PATH" KUBECTL_LOG="$tmp/kubectl.log" \
  CHAOS_TOKEN_ISSUER_KUBECONFIG_B64="$(printf 'test-kubeconfig' | base64 | tr -d '\n')" \
  "$script" >"$tmp/output"
assert_contains "$tmp/output" 'test-dashboard-token'
assert_contains "$tmp/kubectl.log" '-n chaos-mesh auth can-i create serviceaccounts/chaos-dashboard-manager --subresource=token --quiet'
assert_contains "$tmp/kubectl.log" '-n chaos-mesh create token chaos-dashboard-manager --duration=10m'

echo 'SEMAPHORE_CHAOS_DASHBOARD_TOKEN_VALIDATION=PASS'
