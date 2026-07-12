#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gitlab="${ROOT_DIR}/compose/stacks/cicd/gitlab/compose.yaml"
supabase="${ROOT_DIR}/compose/stacks/data/supabase/docker-compose.yml"
kong="${ROOT_DIR}/compose/stacks/data/supabase/volumes/api/kong.yml"
dashy="${ROOT_DIR}/compose/stacks/edge/dashy/config/conf.yml"
dashy_compose="${ROOT_DIR}/compose/stacks/edge/dashy/compose.yaml"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }

item_block() {
  awk -v title="$1" '
    $0 == "      - title: " title { found=1 }
    found { print }
    found && NR > 1 && $0 ~ /^      - title:/ && $0 != "      - title: " title { exit }
  ' "$2"
}

contains "$gitlab" "gitlab_rails['omniauth_auto_sign_in_with_provider'] = 'openid_connect'"
contains "$supabase" 'SUPABASE_ADMIN_HOST: ${SUPABASE_ADMIN_HOST:-supabase-admin.${BASE_DOMAIN}}'
contains "$supabase" 'traefik.http.routers.supabase-admin.rule=Host(`supabase-admin.${BASE_DOMAIN}`)'
contains "$supabase" 'traefik.http.routers.supabase-admin.middlewares=sso-auth@file,dashy-iframe@file'
contains "$kong" 'name: dashboard-keycloak'
contains "$kong" 'hosts:'
contains "$kong" '$SUPABASE_ADMIN_HOST'
contains "$dashy_compose" 'gitlab.${BASE_DOMAIN}:${TAILSCALE_IP:-100.117.59.96}'

dashboard_keycloak="$(sed -n '/name: dashboard-keycloak/,/^  - name:/p' "$kong")"
[[ "$dashboard_keycloak" != *'basic-auth'* ]] || fail 'Keycloak-protected Supabase dashboard route must not retain basic-auth'

gitlab_item="$(item_block GitLab "$dashy")"
supabase_item="$(item_block Supabase "$dashy")"
[[ "$gitlab_item" != *'statusCheckUrl:'* ]] || fail 'GitLab status must use its public HTTPS URL after the Dashy DNS override'
[[ "$gitlab_item" != *'statusCheckAllowInsecure:'* ]] || fail 'GitLab status must not downgrade its HTTPS check'
[[ "$gitlab_item" == *"statusCheckAcceptCodes: '302'"* ]] || fail 'GitLab status must accept the Keycloak redirect'
[[ "$supabase_item" == *'url: https://supabase-admin.imcherry5778.xyz'* ]] || fail 'Supabase card must use the Keycloak-protected admin host'
[[ "$supabase_item" == *"statusCheckAcceptCodes: '302'"* ]] || fail 'Supabase status must accept the Keycloak redirect'

echo 'ADMIN_SSO_ENTRYPOINTS=PASS'
