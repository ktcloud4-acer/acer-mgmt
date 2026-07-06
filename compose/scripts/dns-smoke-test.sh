#!/usr/bin/env bash
set -euo pipefail

BASE_DOMAIN=${BASE_DOMAIN:-imcherry5778.xyz}
ADGUARD_DNS_IP=${ADGUARD_DNS_IP:-100.117.59.96}
EXPECTED_IP=${EXPECTED_IP:-100.117.59.96}
KUBECONFIG_FILE=${KUBECONFIG_FILE:-/home/user1/acer-mgmt/secrets/k3d/mgmt.kubeconfig}

require_cmd() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Missing required command: ${name}" >&2
    exit 1
  fi
}

query_short() {
  local name="$1"
  dig @"$ADGUARD_DNS_IP" "$name" +short
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

require_cmd dig

echo "[1/4] AdGuard wildcard rewrites"
assert_adguard_answer "$BASE_DOMAIN"
assert_adguard_answer "grafana.${BASE_DOMAIN}"
assert_adguard_answer "harbor.${BASE_DOMAIN}"
assert_adguard_answer "argocd.${BASE_DOMAIN}"

echo "[2/4] AdGuard upstream recursion"
external_answer="$(query_short registry-1.docker.io | awk 'NF { print; exit }')"
if [[ -z "$external_answer" ]]; then
  echo "FAIL registry-1.docker.io: empty answer from ${ADGUARD_DNS_IP}" >&2
  exit 1
fi
echo "OK   registry-1.docker.io -> ${external_answer}"

echo "[3/4] mgmt OS resolver"
if getent ahostsv4 "grafana.${BASE_DOMAIN}" | awk '{print $1}' | grep -qx "$EXPECTED_IP"; then
  echo "OK   mgmt OS resolver returns ${EXPECTED_IP}"
else
  echo "WARN mgmt OS resolver did not return ${EXPECTED_IP}; Tailscale Split DNS may not be configured"
fi

echo "[4/4] k3d pod resolver"
if [[ -f "$KUBECONFIG_FILE" ]] && command -v kubectl >/dev/null 2>&1; then
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
