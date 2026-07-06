#!/usr/bin/env bash
set -euo pipefail

KUBECONFIG_FILE=${KUBECONFIG_FILE:-/home/user1/acer-mgmt/secrets/k3d/mgmt.kubeconfig}
DNS_DIR=${DNS_DIR:-/home/user1/acer-mgmt/k3d/bootstrap/dns}

if [[ ! -f "$KUBECONFIG_FILE" ]]; then
  echo "k3d kubeconfig not found: ${KUBECONFIG_FILE}" >&2
  exit 1
fi

KUBECONFIG="$KUBECONFIG_FILE" kubectl apply -k "$DNS_DIR"
KUBECONFIG="$KUBECONFIG_FILE" kubectl -n kube-system rollout restart deploy/coredns
KUBECONFIG="$KUBECONFIG_FILE" kubectl -n kube-system rollout status deploy/coredns --timeout=120s
