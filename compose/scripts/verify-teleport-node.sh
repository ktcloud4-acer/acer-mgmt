#!/usr/bin/env bash
set -Eeuo pipefail

REMOTE_HOST="${REMOTE_HOST:-acer-mgmt}"
TELEPORT_CONTAINER="${TELEPORT_CONTAINER:-teleport}"
NODE_NAME="${NODE_NAME:-acer-mgmt}"
TELEPORT_VERSION="${TELEPORT_VERSION:-18.9.2}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for command in jq ssh tsh; do
  command -v "${command}" >/dev/null 2>&1 || fail "missing command: ${command}"
done

export TELEPORT_ADD_KEYS_TO_AGENT=no

ssh -o BatchMode=yes -o ConnectTimeout=8 "${REMOTE_HOST}" \
  'systemctl is-enabled --quiet teleport-node.service' \
  || fail 'teleport-node.service is not enabled'

ssh -o BatchMode=yes -o ConnectTimeout=8 "${REMOTE_HOST}" \
  'systemctl is-active --quiet teleport-node.service' \
  || fail 'teleport-node.service is not active'

ssh -o BatchMode=yes "${REMOTE_HOST}" \
  'test "$(getenforce)" = Enforcing' \
  || fail 'SELinux is not enforcing'

ssh -o BatchMode=yes "${REMOTE_HOST}" \
  "ps -eZ | grep -Eq 'teleport_ssh_t.*teleport'" \
  || fail 'Teleport is not running in teleport_ssh_t'

ssh -o BatchMode=yes "${REMOTE_HOST}" \
  "/usr/local/bin/teleport version | grep -Fq 'Teleport v${TELEPORT_VERSION} '" \
  || fail "host Teleport is not version ${TELEPORT_VERSION}"

ssh -o BatchMode=yes "${REMOTE_HOST}" \
  'test -z "$(ss -H -ltn '\''sport = :3022'\'')"' \
  || fail 'tunnel-mode Teleport unexpectedly opened inbound port 3022'

ssh -o BatchMode=yes "${REMOTE_HOST}" '
  invocation_id="$(systemctl show teleport-node.service --property=InvocationID --value)"
  test -n "${invocation_id}"
  test -n "$(journalctl --quiet --no-pager --output=cat \
    _SYSTEMD_INVOCATION_ID="${invocation_id}" \
    --grep="Keepalive successful")"
' || fail 'current Teleport service invocation has no healthy reverse tunnel'

ssh -o BatchMode=yes "${REMOTE_HOST}" \
  'test ! -e /var/lib/teleport-node/join.token && test ! -e /root/teleport-native-node.token' \
  || fail 'a native join token file still exists'

ssh -o BatchMode=yes "${REMOTE_HOST}" '
  set -e
  test ! -e /root/teleport-agentless-pilot
  test ! -e /etc/ssh/sshd_config.d/90-teleport.conf
  test "$(/usr/sbin/sshd -T | awk '\''$1 == "trustedusercakeys" {print $2}'\'')" = none
  test -z "$(find /etc/ssh -maxdepth 2 -type f -iname "*teleport*" -print -quit)"
' || fail 'Agentless OpenSSH host residue is present'

node_id="$(ssh -o BatchMode=yes "${REMOTE_HOST}" \
  'tr -d '\''\r\n'\'' < /var/lib/teleport-node/host_uuid')"
[[ -n "${node_id}" ]] || fail 'native node host UUID is empty'

node_json="$(ssh -o BatchMode=yes "${REMOTE_HOST}" \
  "docker exec ${TELEPORT_CONTAINER} tctl nodes ls --format=json")"

agentless_node_count="$(jq \
  '[.[] | select((.sub_kind // "") == "openssh")] | length' \
  <<<"${node_json}")"
[[ "${agentless_node_count}" == '0' ]] \
  || fail "expected zero Agentless nodes, got ${agentless_node_count}"

native_hostname_count="$(jq --arg name "${NODE_NAME}" \
  '[.[] | select(
    .spec.hostname == $name and
    ((.sub_kind // "") != "openssh")
  )] | length' <<<"${node_json}")"
[[ "${native_hostname_count}" == '1' ]] \
  || fail "expected exactly one native ${NODE_NAME} node, got ${native_hostname_count}"

node_count="$(jq --arg id "${node_id}" --arg name "${NODE_NAME}" \
  --arg version "${TELEPORT_VERSION}" '
    [.[] | select(
      .metadata.name == $id and
      .spec.hostname == $name and
      ((.sub_kind // "") != "openssh") and
      .spec.version == $version
    )] | length
  ' <<<"${node_json}")"
[[ "${node_count}" == '1' ]] \
  || fail "expected one native ${NODE_NAME} node with ID ${node_id}, got ${node_count}"

jq -e --arg id "${node_id}" '
  [.[] | select(
    .metadata.name == $id and
    .metadata.labels.env == "mgmt" and
    .metadata.labels.owner == "infra"
  )] | length == 1
' <<<"${node_json}" >/dev/null || fail 'native node labels are incorrect'

client_node_count="$(tsh ls --format=json | jq --arg id "${node_id}" \
  --arg name "${NODE_NAME}" \
  '[.[] | select(
    .metadata.name == $id and
    .spec.hostname == $name and
    ((.sub_kind // "") != "openssh")
  )] | length')"
[[ "${client_node_count}" == '1' ]] \
  || fail "tsh sees ${client_node_count} matching native ${NODE_NAME} nodes"

client_native_hostname_count="$(tsh ls --format=json | jq --arg name "${NODE_NAME}" \
  '[.[] | select(
    .spec.hostname == $name and
    ((.sub_kind // "") != "openssh")
  )] | length')"
[[ "${client_native_hostname_count}" == '1' ]] \
  || fail "tsh sees ${client_native_hostname_count} native ${NODE_NAME} nodes"

teleport_user="$(tsh status --format=json | jq -r '.active.username // empty')"
[[ -n "${teleport_user}" ]] || fail 'no active Teleport user profile'

audit_start="$(date -u +%s)"
native_result="$(tsh ssh "user1@${NODE_NAME}" 'id -un; hostname')" \
  || fail 'native Teleport SSH connection failed'
[[ "${native_result}" == $'user1\nacer-mgmt' ]] \
  || fail "unexpected native SSH identity: ${native_result//$'\n'/ }"

direct_result="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "${REMOTE_HOST}" \
  'id -un; systemctl is-active sshd')" || fail 'direct SSH safety path failed'
[[ "${direct_result}" == $'root\nactive' ]] \
  || fail "unexpected direct SSH result: ${direct_result//$'\n'/ }"

audit_found='false'
for _ in {1..20}; do
  recordings_json="$(tsh recordings ls --format=json)" \
    || fail 'failed to query structured Teleport session records'
  if jq -e --arg id "${node_id}" --arg name "${NODE_NAME}" \
    --arg user "${teleport_user}" --argjson since "${audit_start}" '
      any(.[];
        .event == "session.end" and
        .server_id == $id and
        .server_hostname == $name and
        .server_sub_kind == "teleport" and
        .login == "user1" and
        .user == $user and
        (((.session_start // ""
          | sub("\\.[0-9]+Z$"; "Z")
          | fromdateiso8601?) // 0) >= $since)
      )
    ' <<<"${recordings_json}" >/dev/null; then
    audit_found='true'
    break
  fi
  sleep 1
done
[[ "${audit_found}" == 'true' ]] \
  || fail 'structured audit records have no matching native SSH session'

printf 'PASS: native Teleport SSH node %s is healthy\n' "${NODE_NAME}"
