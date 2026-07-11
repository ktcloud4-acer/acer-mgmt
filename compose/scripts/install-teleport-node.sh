#!/usr/bin/env bash
set -Eeuo pipefail

readonly TELEPORT_VERSION='18.9.2'
readonly TELEPORT_SHA256='6e8d81d2e355d1a2a5176c2be70854b35f63522db8ff8e4db6437de81a1d1268'
readonly NODE_NAME='acer-mgmt'
readonly NODE_DATA_DIR='/var/lib/teleport-node'
readonly NODE_CONFIG='/etc/teleport-node.yaml'
readonly NODE_UNIT='/etc/systemd/system/teleport-node.service'
readonly NODE_TOKEN='/var/lib/teleport-node/join.token'
readonly TELEPORT_BINARY='/usr/local/bin/teleport'

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

if [[ "${EUID}" -ne 0 ]]; then
  fail 'run this installer as root'
fi

if [[ "$#" -ne 1 ]]; then
  fail "usage: $0 /path/to/root-only-node-token"
fi

source_token="$1"
[[ -f "${source_token}" && ! -L "${source_token}" ]] \
  || fail "join token must be a regular, non-symlink file: ${source_token}"
[[ "$(stat -c '%u' "${source_token}")" == '0' ]] \
  || fail 'join token file must be owned by root'
token_mode="$(stat -c '%a' "${source_token}")"
(( (8#${token_mode} & 8#077) == 0 )) \
  || fail 'join token file must not be accessible by group or other users'
[[ "$(readlink -f "${source_token}")" != "${NODE_TOKEN}" ]] \
  || fail "source token must be outside ${NODE_DATA_DIR}"

join_token="$(tr -d '\r\n' < "${source_token}")"
[[ -n "${join_token}" ]] || fail 'join token file is empty'
[[ "$(getenforce)" == 'Enforcing' ]] || fail 'SELinux must be Enforcing'

for command in awk cp curl dnf docker find getenforce install journalctl jq \
  readlink restorecon semodule sha256sum sshd stat systemctl tar tr; do
  command -v "${command}" >/dev/null 2>&1 || fail "missing command: ${command}"
done

script_path="$(readlink -f "${BASH_SOURCE[0]}")"
script_dir="$(dirname "${script_path}")"
compose_dir="$(cd "${script_dir}/.." && pwd -P)"
config_source="${compose_dir}/stacks/security/teleport/node/acer-mgmt.yaml"
unit_source="${compose_dir}/systemd/teleport-node.service"

[[ -f "${config_source}" ]] || fail "missing node config: ${config_source}"
[[ -f "${unit_source}" ]] || fail "missing systemd unit: ${unit_source}"
[[ ! -e /root/teleport-agentless-pilot ]] || fail 'Agentless pilot residue still exists'
[[ ! -e /etc/ssh/sshd_config.d/90-teleport.conf ]] \
  || fail 'Agentless sshd include still exists'

trusted_user_ca="$(/usr/sbin/sshd -T | awk '$1 == "trustedusercakeys" {print $2}')"
[[ "${trusted_user_ca}" == 'none' ]] || fail 'Agentless TrustedUserCAKeys is still active'

agentless_ssh_file="$(find /etc/ssh -maxdepth 2 -type f -iname '*teleport*' -print -quit)"
[[ -z "${agentless_ssh_file}" ]] \
  || fail "Agentless SSH artifact still exists: ${agentless_ssh_file}"

agentless_node_count="$(docker exec teleport tctl nodes ls --format=json \
  | jq '[.[] | select((.sub_kind // "") == "openssh")] | length')"
[[ "${agentless_node_count}" == '0' ]] || fail 'Agentless OpenSSH node resource still exists'

work_dir="$(mktemp -d /root/teleport-node-install.XXXXXXXX)"
backup_dir="${work_dir}/backup"
mkdir -m 0700 "${backup_dir}"

binary_existed='false'
config_existed='false'
unit_existed='false'
data_dir_existed='false'
module_existed='false'
module_priority=''
unit_was_enabled='false'
unit_was_active='false'
original_node_id=''
original_node_present='false'
rollback_needed='false'
token_revoked='false'

if [[ -e "${TELEPORT_BINARY}" || -L "${TELEPORT_BINARY}" ]]; then
  binary_existed='true'
  cp -a "${TELEPORT_BINARY}" "${backup_dir}/teleport"
fi
if [[ -e "${NODE_CONFIG}" || -L "${NODE_CONFIG}" ]]; then
  config_existed='true'
  cp -a "${NODE_CONFIG}" "${backup_dir}/teleport-node.yaml"
fi
if [[ -e "${NODE_UNIT}" || -L "${NODE_UNIT}" ]]; then
  unit_existed='true'
  cp -a "${NODE_UNIT}" "${backup_dir}/teleport-node.service"
fi
if [[ -d "${NODE_DATA_DIR}" ]]; then
  data_dir_existed='true'
  cp -a "${NODE_DATA_DIR}" "${backup_dir}/teleport-node-data"
  rm -f "${backup_dir}/teleport-node-data/debug.sock"
  if [[ -s "${NODE_DATA_DIR}/host_uuid" ]]; then
    original_node_id="$(tr -d '\r\n' < "${NODE_DATA_DIR}/host_uuid")"
    if docker exec teleport tctl nodes ls --format=json \
      | jq -e --arg id "${original_node_id}" \
        '[.[] | select(.metadata.name == $id)] | length == 1' >/dev/null; then
      original_node_present='true'
    fi
  fi
fi
module_priority="$(semodule -lfull \
  | awk '$2 == "teleport_ssh" && value == "" {value = $1} END {print value}')"
if [[ -n "${module_priority}" ]]; then
  module_existed='true'
  (
    cd "${backup_dir}"
    semodule -X "${module_priority}" -E teleport_ssh
  )
fi
systemctl is-enabled --quiet teleport-node.service && unit_was_enabled='true' || true
systemctl is-active --quiet teleport-node.service && unit_was_active='true' || true

restore_file() {
  local destination="$1"
  local backup="$2"
  local existed="$3"

  rm -f "${destination}"
  if [[ "${existed}" == 'true' ]]; then
    cp -a "${backup}" "${destination}"
  fi
}

cleanup() {
  local status=$?
  local node_id=''

  trap - EXIT INT TERM

  if [[ "${status}" -ne 0 ]]; then
    if [[ "${token_revoked}" != 'true' ]]; then
      docker exec teleport tctl tokens rm "${join_token}" >/dev/null 2>&1 || true
    fi

    if [[ "${rollback_needed}" == 'true' ]]; then
      printf 'Installation failed; restoring the previous Teleport node state.\n' >&2
      systemctl stop teleport-node.service >/dev/null 2>&1 || true
      systemctl disable teleport-node.service >/dev/null 2>&1 || true

      if [[ -s "${NODE_DATA_DIR}/host_uuid" ]]; then
        node_id="$(tr -d '\r\n' < "${NODE_DATA_DIR}/host_uuid")"
        if [[ "${node_id}" != "${original_node_id}" \
          || "${original_node_present}" != 'true' ]]; then
          docker exec teleport tctl rm "node/${node_id}" >/dev/null 2>&1 || true
        fi
      fi

      restore_file "${TELEPORT_BINARY}" "${backup_dir}/teleport" "${binary_existed}"
      restore_file "${NODE_CONFIG}" "${backup_dir}/teleport-node.yaml" "${config_existed}"
      restore_file "${NODE_UNIT}" "${backup_dir}/teleport-node.service" "${unit_existed}"

      rm -rf "${NODE_DATA_DIR}"
      if [[ "${data_dir_existed}" == 'true' ]]; then
        cp -a "${backup_dir}/teleport-node-data" "${NODE_DATA_DIR}"
      fi
      semodule -X 400 -r teleport_ssh >/dev/null 2>&1 || true
      if [[ "${module_existed}" == 'true' ]]; then
        semodule -X "${module_priority}" \
          -i "${backup_dir}/teleport_ssh.pp" >/dev/null 2>&1 || true
      fi

      rm -f /run/teleport.pid
      systemctl daemon-reload >/dev/null 2>&1 || true
      if [[ "${unit_was_enabled}" == 'true' ]]; then
        systemctl enable teleport-node.service >/dev/null 2>&1 || true
      fi
      if [[ "${unit_was_active}" == 'true' ]]; then
        systemctl start teleport-node.service >/dev/null 2>&1 || true
      fi
      systemctl reset-failed teleport-node.service >/dev/null 2>&1 || true
    fi
  fi

  rm -f "${source_token}" "${NODE_TOKEN}"
  rm -rf "${work_dir}"
  unset join_token
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for_native_tunnel() {
  local attempts="$1"
  local attempt=0
  local invocation_id=''
  local node_id=''
  local tunnel_log=''

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if systemctl is-active --quiet teleport-node.service \
      && [[ -s "${NODE_DATA_DIR}/host_uuid" ]]; then
      invocation_id="$(systemctl show teleport-node.service \
        --property=InvocationID --value)"
      node_id="$(tr -d '\r\n' < "${NODE_DATA_DIR}/host_uuid")"
      tunnel_log="$(journalctl --quiet --no-pager --output=cat \
        _SYSTEMD_INVOCATION_ID="${invocation_id}" \
        --grep='Keepalive successful')"

      if [[ -n "${invocation_id}" && -n "${node_id}" && -n "${tunnel_log}" ]] \
        && docker exec teleport tctl nodes ls --format=json \
          | jq -e --arg id "${node_id}" --arg name "${NODE_NAME}" \
            --arg version "${TELEPORT_VERSION}" '
              [.[] | select(
                .metadata.name == $id and
                .spec.hostname == $name and
                ((.sub_kind // "") != "openssh") and
                .spec.version == $version
              )] | length == 1
            ' >/dev/null; then
        return 0
      fi
    fi
    sleep 1
  done

  return 1
}

archive="teleport-v${TELEPORT_VERSION}-linux-amd64-bin.tar.gz"
archive_url="https://cdn.teleport.dev/${archive}"

cd "${work_dir}"
curl -fsSLO "${archive_url}"
printf '%s  %s\n' "${TELEPORT_SHA256}" "${archive}" | sha256sum --check -
tar -xzf "${archive}"
[[ -x "${work_dir}/teleport/teleport" ]] || fail 'Teleport binary missing from archive'

rollback_needed='true'
install -m 0755 "${work_dir}/teleport/teleport" "${TELEPORT_BINARY}"
install -m 0644 "${config_source}" "${NODE_CONFIG}"
install -m 0644 "${unit_source}" "${NODE_UNIT}"
install -d -m 0750 "${NODE_DATA_DIR}"
install -m 0600 /dev/null "${NODE_TOKEN}"
printf '%s\n' "${join_token}" > "${NODE_TOKEN}"

dnf install -y selinux-policy-devel
"${work_dir}/teleport/install-selinux.sh" \
  -c "${NODE_CONFIG}" \
  -t "${TELEPORT_BINARY}"
restorecon -RFv "${TELEPORT_BINARY}" "${NODE_CONFIG}" "${NODE_DATA_DIR}"

systemctl daemon-reload
systemctl enable teleport-node.service
systemctl restart teleport-node.service

if ! wait_for_native_tunnel 45; then
  journalctl -u teleport-node.service -n 120 --no-pager >&2
  fail 'native Teleport node did not establish a fresh tunnel within 45 seconds'
fi

docker exec teleport tctl tokens rm "${join_token}" >/dev/null
token_revoked='true'
rm -f "${source_token}" "${NODE_TOKEN}"
systemctl restart teleport-node.service

if ! wait_for_native_tunnel 30; then
  journalctl -u teleport-node.service -n 120 --no-pager >&2
  fail 'native Teleport node did not establish a fresh token-free tunnel after restart'
fi

systemctl is-enabled --quiet teleport-node.service
test ! -e "${source_token}"
test ! -e "${NODE_TOKEN}"
rollback_needed='false'
printf 'Native Teleport SSH node %s enrolled with Teleport %s\n' \
  "${NODE_NAME}" "${TELEPORT_VERSION}"
