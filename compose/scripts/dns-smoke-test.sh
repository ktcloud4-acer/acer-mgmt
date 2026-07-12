#!/usr/bin/env bash
set -euo pipefail

BASE_DOMAIN=${BASE_DOMAIN:-imcherry5778.xyz}
ADGUARD_DNS_IP=${ADGUARD_DNS_IP:-100.117.59.96}
EXPECTED_IP=${EXPECTED_IP:-100.117.59.96}
KUBECONFIG_FILE=${KUBECONFIG_FILE:-/home/user1/acer-mgmt/secrets/k3d/mgmt.kubeconfig}
DNS_SMOKE_REQUIRE_DIRECT=${DNS_SMOKE_REQUIRE_DIRECT:-false}
DNS_SMOKE_DISABLE_DIRECT=${DNS_SMOKE_DISABLE_DIRECT:-false}

has_cmd() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1
}

is_truthy() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

query_short() {
  local name="$1"
  if ! is_truthy "$DNS_SMOKE_DISABLE_DIRECT" && has_cmd dig; then
    dig @"$ADGUARD_DNS_IP" "$name" +short
  elif ! is_truthy "$DNS_SMOKE_DISABLE_DIRECT" && has_cmd nslookup; then
    nslookup "$name" "$ADGUARD_DNS_IP" | awk '/^Address: / { answer=$2 } END { sub(/#.*/, "", answer); if (answer != "") print answer }'
  elif has_cmd getent; then
    getent ahostsv4 "$name" | awk 'NF { print $1; exit }'
  else
    echo "Missing DNS query command: dig, nslookup, or getent" >&2
    exit 1
  fi
}

has_direct_dns_tool() {
  ! is_truthy "$DNS_SMOKE_DISABLE_DIRECT" && { has_cmd dig || has_cmd nslookup; }
}

assert_adguard_answer() {
  local name="$1"
  local answer
  answer="$(query_short "$name" | awk 'NF { print; exit }')"
  if [[ "$answer" != "$EXPECTED_IP" ]]; then
    echo "FAIL ${name}: expected ${EXPECTED_IP}, got ${answer:-<empty>}" >&2
    exit 1
  fi
  echo "OK   ${name} -> ${answer}"
}

echo "[1/4] AdGuard service rewrites"
if has_direct_dns_tool; then
  assert_adguard_answer "grafana.${BASE_DOMAIN}"
  assert_adguard_answer "alertmanager.${BASE_DOMAIN}"
  assert_adguard_answer "harbor.${BASE_DOMAIN}"
  assert_adguard_answer "argocd.${BASE_DOMAIN}"
  assert_adguard_answer "keycloak.${BASE_DOMAIN}"
  assert_adguard_answer "dash.${BASE_DOMAIN}"
  assert_adguard_answer "wazuh.${BASE_DOMAIN}"
  assert_adguard_answer "redis.${BASE_DOMAIN}"
  assert_adguard_answer "n8n.${BASE_DOMAIN}"
  assert_adguard_answer "teleport.${BASE_DOMAIN}"
  assert_adguard_answer "tp-alertmanager.${BASE_DOMAIN}"
  assert_adguard_answer "supabase-admin.${BASE_DOMAIN}"
elif is_truthy "$DNS_SMOKE_REQUIRE_DIRECT"; then
  echo "Missing direct DNS query command: dig or nslookup" >&2
  exit 1
else
  echo "SKIP direct AdGuard DNS checks: install dig or nslookup for @${ADGUARD_DNS_IP} queries"
fi

echo "[2/4] AdGuard upstream recursion"
if has_direct_dns_tool; then
  external_answer="$(query_short registry-1.docker.io | awk 'NF { print; exit }')"
  if [[ -z "$external_answer" ]]; then
    echo "FAIL registry-1.docker.io: empty answer from ${ADGUARD_DNS_IP}" >&2
    exit 1
  fi
  echo "OK   registry-1.docker.io -> ${external_answer}"
else
  echo "SKIP direct AdGuard recursion check: install dig or nslookup"
fi

echo "[3/4] mgmt OS resolver"
if has_cmd getent && getent ahostsv4 "grafana.${BASE_DOMAIN}" | awk '{print $1}' | grep -qx "$EXPECTED_IP"; then
  echo "OK   mgmt OS resolver returns ${EXPECTED_IP}"
else
  echo "WARN mgmt OS resolver did not return ${EXPECTED_IP}; Tailscale Split DNS may not be configured"
fi

echo "[4/4] k3d pod resolver"
if [[ -f "$KUBECONFIG_FILE" ]] && has_cmd kubectl; then
  if KUBECONFIG="$KUBECONFIG_FILE" kubectl -n argocd exec deploy/argocd-server -- \
    getent ahostsv4 "harbor.${BASE_DOMAIN}" 2>/dev/null | awk '{print $1}' | grep -qx "$EXPECTED_IP"; then
    echo "OK   k3d pod resolver returns ${EXPECTED_IP}"
  else
    echo "WARN k3d pod resolver did not return ${EXPECTED_IP}; check coredns-custom and k3d node DNS"
  fi
else
  echo "SKIP k3d pod resolver check"
fi

echo "DNS smoke test completed"
