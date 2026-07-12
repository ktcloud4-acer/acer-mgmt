#!/usr/bin/env bash
set -euo pipefail

# Grafana Auth Proxy accepts a user header only from Traefik's fixed address
# on this isolated network. Keep Grafana's data-source traffic on a separate
# private network so no shared mgmt-proxy peer can forge that header.
AUTH_NETWORK=${TRAEFIK_GRAFANA_AUTH_NET:-traefik-grafana-auth}
AUTH_SUBNET=${TRAEFIK_GRAFANA_AUTH_SUBNET:-172.31.254.0/29}
OBS_NETWORK=${GRAFANA_OBSERVABILITY_NET:-grafana-observability}
OBS_SUBNET=${GRAFANA_OBSERVABILITY_SUBNET:-172.31.253.0/29}

command -v docker >/dev/null 2>&1 || {
  echo 'docker is required' >&2
  exit 1
}

ensure_network() {
  network_name=$1
  expected_subnet=$2

  if docker network inspect "$network_name" >/dev/null 2>&1; then
    actual_subnet=$(docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$network_name")
    if [ "$actual_subnet" != "$expected_subnet" ]; then
      echo "network $network_name has subnet $actual_subnet; expected $expected_subnet" >&2
      exit 1
    fi
    return
  fi

  docker network create --driver bridge --subnet "$expected_subnet" "$network_name" >/dev/null
}

ensure_network "$AUTH_NETWORK" "$AUTH_SUBNET"
ensure_network "$OBS_NETWORK" "$OBS_SUBNET"

echo 'Dashy SSO networks reconciled.'
