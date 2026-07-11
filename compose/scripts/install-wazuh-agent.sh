#!/usr/bin/env bash
# Install and enroll a Wazuh 4.14 agent on a supported Linux host.
# Run as root on acer-mgmt/acer-aio after the central manager is healthy.
set -euo pipefail

WAZUH_MANAGER="${WAZUH_MANAGER:?WAZUH_MANAGER must be set}"
WAZUH_AGENT_NAME="${WAZUH_AGENT_NAME:-$(hostname -s)}"
WAZUH_AGENT_GROUP="${WAZUH_AGENT_GROUP:-default}"
SECRETS_FILE="${WAZUH_AGENT_SECRETS_FILE:-/run/acer-mgmt/secrets/security/wazuh-agent.env}"

[[ $EUID -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }
[[ -r "$SECRETS_FILE" ]] || { echo "Missing Wazuh agent secret: $SECRETS_FILE" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$SECRETS_FILE"
set +a
: "${WAZUH_REGISTRATION_PASSWORD:?missing WAZUH_REGISTRATION_PASSWORD}"

if command -v dnf >/dev/null 2>&1; then
  rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH
  cat >/etc/yum.repos.d/wazuh.repo <<'EOF'
[wazuh]
gpgcheck=1
gpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH
enabled=1
name=EL-$releasever - Wazuh
baseurl=https://packages.wazuh.com/4.x/yum/
protect=1
EOF
  WAZUH_MANAGER="$WAZUH_MANAGER" \
  WAZUH_REGISTRATION_SERVER="$WAZUH_MANAGER" \
  WAZUH_REGISTRATION_PASSWORD="$WAZUH_REGISTRATION_PASSWORD" \
  WAZUH_AGENT_NAME="$WAZUH_AGENT_NAME" \
  WAZUH_AGENT_GROUP="$WAZUH_AGENT_GROUP" \
    dnf install -y wazuh-agent
elif command -v apt-get >/dev/null 2>&1; then
  curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor >/usr/share/keyrings/wazuh.gpg
  printf 'deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main\n' >/etc/apt/sources.list.d/wazuh.list
  apt-get update
  WAZUH_MANAGER="$WAZUH_MANAGER" \
  WAZUH_REGISTRATION_SERVER="$WAZUH_MANAGER" \
  WAZUH_REGISTRATION_PASSWORD="$WAZUH_REGISTRATION_PASSWORD" \
  WAZUH_AGENT_NAME="$WAZUH_AGENT_NAME" \
  WAZUH_AGENT_GROUP="$WAZUH_AGENT_GROUP" \
    apt-get install -y wazuh-agent
else
  echo 'Unsupported package manager; install the Wazuh 4.14 agent manually.' >&2
  exit 1
fi

systemctl enable --now wazuh-agent
systemctl is-active --quiet wazuh-agent
echo "Wazuh agent enrolled: ${WAZUH_AGENT_NAME} -> ${WAZUH_MANAGER}"
