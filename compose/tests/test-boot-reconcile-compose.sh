#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCRIPT="${REPO_ROOT}/compose/scripts/boot-reconcile.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" || fail "expected '${expected}' in ${file}"
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -Fq -- "$unexpected" "$file"; then
    fail "did not expect '${unexpected}' in ${file}"
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake_bin="${tmp}/bin"
calls="${tmp}/calls.log"
stdout="${tmp}/stdout.log"
compose_root="${tmp}/acer-mgmt/compose"
mkdir -p \
  "$fake_bin" \
  "${compose_root}/stacks/edge/gitlab" \
  "${tmp}/acer-mgmt/run/acer-mgmt/secrets/edge"

touch \
  "${tmp}/acer-mgmt/.env" \
  "${compose_root}/stacks/edge/gitlab/.env" \
  "${tmp}/acer-mgmt/run/acer-mgmt/secrets/edge/gitlab.env"

cat >"${compose_root}/stacks/edge/gitlab/compose.yaml" <<'YAML'
services:
  gitlab:
    image: example/gitlab
    ports:
      - "${TAILSCALE_IP}:8443:443"
YAML

cat >"${fake_bin}/tailscale" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "ip" && "$2" == "-4" ]]; then
  echo "100.117.59.96"
fi
SH

cat >"${fake_bin}/ip" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == " -4 addr show tailscale0" || "$*" == "-4 addr show tailscale0" ]]; then
  echo "inet 100.117.59.96/32 scope global tailscale0"
fi
SH

cat >"${fake_bin}/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat >"${fake_bin}/make" <<'SH'
#!/usr/bin/env bash
echo "MAKE $*" >>"${CALLS}"
exit 0
SH

cat >"${fake_bin}/docker" <<'SH'
#!/usr/bin/env bash
printf 'DOCKER' >>"${CALLS}"
for arg in "$@"; do
  printf ' %s' "$arg" >>"${CALLS}"
done
printf '\n' >>"${CALLS}"

if [[ "$1" == "inspect" && "${2:-}" == "harbor-log" ]]; then
  exit 1
fi
exit 0
SH

chmod +x "${fake_bin}/tailscale" "${fake_bin}/ip" "${fake_bin}/sleep" "${fake_bin}/make" "${fake_bin}/docker"

PATH="${fake_bin}:/usr/bin:/bin" \
  CALLS="$calls" \
  ACER_MGMT_REPO="$compose_root" \
  VAULT_ENV_ROOT="${tmp}/acer-mgmt/run/acer-mgmt/secrets" \
  "$SCRIPT" >"$stdout" 2>&1

assert_not_contains "$calls" "MAKE "
assert_contains "$calls" "DOCKER network inspect mgmt-proxy"
assert_contains "$calls" "DOCKER network inspect mgmt-data"
assert_contains "$calls" "DOCKER compose --env-file ../.env --env-file stacks/edge/gitlab/.env --env-file ${tmp}/acer-mgmt/run/acer-mgmt/secrets/edge/gitlab.env -f stacks/edge/gitlab/compose.yaml up -d"

echo "boot reconcile compose tests passed"
