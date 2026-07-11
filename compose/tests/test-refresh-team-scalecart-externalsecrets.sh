#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$root_dir/compose/scripts/refresh-team-scalecart-externalsecrets.sh"

fail() {
  echo "TEAM_EXTERNAL_SECRET_REFRESH_VALIDATION=FAIL: $*" >&2
  exit 1
}

[[ -f "$script" ]] || fail "refresh script is missing"
for team in ggg khb ljw nmg oje; do
  grep -Fq "$team" "$script" || fail "team $team is missing"
done
grep -Fq 'argocd.argoproj.io/secret-type' "$script" || fail "Argo cluster Secret label validation is missing"
grep -Fq 'externalsecret scalecart' "$script" || fail "ScaleCart ExternalSecret refresh is missing"
grep -Fq 'force-sync=' "$script" || fail "force-sync annotation is missing"
grep -Fq 'insecure-skip-tls-verify' "$script" || fail "Argo cluster TLS mode must be preserved"
! grep -Fq 'echo "$token"' "$script" || fail "token must not be printed"

echo "TEAM_EXTERNAL_SECRET_REFRESH_VALIDATION=PASS"
