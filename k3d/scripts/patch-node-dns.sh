#!/usr/bin/env bash
set -euo pipefail

CONTAINER=${CONTAINER:-k3d-mgmt-server-0}
PRIMARY_DNS=${PRIMARY_DNS:-100.117.59.96}
FALLBACK_DNS=${FALLBACK_DNS:-100.100.100.100}
SEARCH_DOMAINS=${SEARCH_DOMAINS:-tailc0244b.ts.net lan}

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "k3d node container not found: ${CONTAINER}" >&2
  exit 1
fi

stamp="$(TZ=Asia/Seoul date +%Y%m%dT%H%M%SKST)"
docker exec "$CONTAINER" cp /etc/resolv.conf "/etc/resolv.conf.pre-adguard-${stamp}"

docker exec \
  -e PRIMARY_DNS="$PRIMARY_DNS" \
  -e FALLBACK_DNS="$FALLBACK_DNS" \
  -e SEARCH_DOMAINS="$SEARCH_DOMAINS" \
  "$CONTAINER" sh -ec '
    {
      echo "# Managed by acer-mgmt/k3d/scripts/patch-node-dns.sh"
      echo "nameserver ${PRIMARY_DNS}"
      echo "nameserver ${FALLBACK_DNS}"
      echo "search ${SEARCH_DOMAINS}"
      echo "options ndots:0"
    } > /etc/resolv.conf
  '

docker exec "$CONTAINER" nslookup registry-1.docker.io "$PRIMARY_DNS" >/dev/null
docker exec "$CONTAINER" nslookup harbor.imcherry5778.xyz "$PRIMARY_DNS" >/dev/null

echo "Patched ${CONTAINER} /etc/resolv.conf; backup is /etc/resolv.conf.pre-adguard-${stamp}"
