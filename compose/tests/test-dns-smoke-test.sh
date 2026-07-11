#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ROOT_DIR}/compose/scripts/dns-smoke-test.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq "$expected" "$file" || fail "expected '${expected}' in ${file}"
}

test_script_is_executable() {
  [[ -x "$SCRIPT" ]] || fail "expected executable script: ${SCRIPT}"
}

test_direct_dns_checks_skip_apex_domain() {
  local tmp fake_bin stdout stderr
  tmp="$(mktemp -d)"
  fake_bin="${tmp}/bin"
  stdout="${tmp}/stdout"
  stderr="${tmp}/stderr"
  mkdir -p "$fake_bin"

  cat >"${fake_bin}/dig" <<'SH'
#!/usr/bin/env bash
name=""
for arg in "$@"; do
  case "$arg" in
    @*|+*) ;;
    *) name="$arg" ;;
  esac
done

case "$name" in
  imcherry5778.xyz)
    exit 0
    ;;
  grafana.imcherry5778.xyz|alertmanager.imcherry5778.xyz|harbor.imcherry5778.xyz|argocd.imcherry5778.xyz|keycloak.imcherry5778.xyz|kuma.imcherry5778.xyz|n8n.imcherry5778.xyz|teleport.imcherry5778.xyz|tp-alertmanager.imcherry5778.xyz)
    echo "${EXPECTED_IP:-100.117.59.96}"
    ;;
  registry-1.docker.io)
    echo "44.205.64.79"
    ;;
  *)
    exit 1
    ;;
esac
SH
  cat >"${fake_bin}/getent" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "ahostsv4" ]]; then
  echo "${EXPECTED_IP:-100.117.59.96} STREAM $2"
fi
SH
  chmod +x "${fake_bin}/dig" "${fake_bin}/getent"

  PATH="${fake_bin}:/usr/bin:/bin" \
    BASE_DOMAIN="imcherry5778.xyz" \
    EXPECTED_IP="100.117.59.96" \
    KUBECONFIG_FILE="${tmp}/missing.kubeconfig" \
    "$SCRIPT" >"$stdout" 2>"$stderr"

  assert_contains "$stdout" "OK   grafana.imcherry5778.xyz -> 100.117.59.96"
  assert_contains "$stdout" "OK   alertmanager.imcherry5778.xyz -> 100.117.59.96"
  assert_contains "$stdout" "OK   harbor.imcherry5778.xyz -> 100.117.59.96"
  assert_contains "$stdout" "OK   argocd.imcherry5778.xyz -> 100.117.59.96"
  assert_contains "$stdout" "OK   keycloak.imcherry5778.xyz -> 100.117.59.96"
  assert_contains "$stdout" "OK   kuma.imcherry5778.xyz -> 100.117.59.96"
  assert_contains "$stdout" "OK   n8n.imcherry5778.xyz -> 100.117.59.96"
  assert_contains "$stdout" "OK   teleport.imcherry5778.xyz -> 100.117.59.96"
  assert_contains "$stdout" "OK   tp-alertmanager.imcherry5778.xyz -> 100.117.59.96"
  assert_contains "$stdout" "DNS smoke test completed"
}

test_getent_fallback_without_direct_dns_tools() {
  local tmp fake_bin stdout stderr
  tmp="$(mktemp -d)"
  fake_bin="${tmp}/bin"
  stdout="${tmp}/stdout"
  stderr="${tmp}/stderr"
  mkdir -p "$fake_bin"

  cat >"${fake_bin}/getent" <<'SH'
#!/usr/bin/env bash
if [[ "$1" != "ahostsv4" ]]; then
  exit 1
fi
case "$2" in
  registry-1.docker.io)
    echo "44.205.64.79 STREAM registry-1.docker.io"
    ;;
  *)
    echo "${EXPECTED_IP:-100.117.59.96} STREAM $2"
    ;;
esac
SH
  chmod +x "${fake_bin}/getent"

  PATH="${fake_bin}:/usr/bin:/bin" \
    BASE_DOMAIN="imcherry5778.xyz" \
    DNS_SMOKE_DISABLE_DIRECT=true \
    EXPECTED_IP="100.117.59.96" \
    KUBECONFIG_FILE="${tmp}/missing.kubeconfig" \
    "$SCRIPT" >"$stdout" 2>"$stderr"

  assert_contains "$stdout" "SKIP direct AdGuard DNS checks"
  assert_contains "$stdout" "DNS smoke test completed"
}

test_script_is_executable
test_direct_dns_checks_skip_apex_domain
test_getent_fallback_without_direct_dns_tools

echo "dns-smoke-test tests passed"
