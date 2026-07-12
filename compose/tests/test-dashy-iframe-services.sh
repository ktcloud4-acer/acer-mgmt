#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MIDDLEWARES="${ROOT_DIR}/compose/stacks/edge/traefik/config/dynamic/middlewares.yaml"
K3D="${ROOT_DIR}/compose/stacks/edge/traefik/config/dynamic/k3d.yaml"
HARBOR="${ROOT_DIR}/compose/stacks/cicd/harbor/compose.traefik.yaml"
SUPABASE="${ROOT_DIR}/compose/stacks/data/supabase/docker-compose.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }

# These applications send restrictive upstream frame policies. Their public UI
# routes must replace them with a policy that permits Dashy's Workspace only.
contains "$MIDDLEWARES" 'dashy-iframe:'
contains "$MIDDLEWARES" "Content-Security-Policy: \"frame-ancestors https://dashy.imcherry5778.xyz; object-src 'none'; base-uri 'self';\""
contains "$MIDDLEWARES" 'X-Frame-Options: ""'

contains "$K3D" 'k3d-argocd:'
contains "$K3D" '- dashy-iframe'
contains "$HARBOR" 'traefik.http.routers.harbor.middlewares=dashy-iframe@file'
contains "$SUPABASE" 'traefik.http.routers.supabase-admin.middlewares=sso-auth@file,dashy-iframe@file'

echo 'DASHY_IFRAME_SERVICES=PASS'
