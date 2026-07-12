#!/usr/bin/env bash
# Read-only verification of the ACER security best-practice boundaries.
set -euo pipefail

BASE_DOMAIN="${BASE_DOMAIN:-imcherry5778.xyz}"
DATA_ROOT="${DATA_ROOT:-/home/mgmt-data}"
SECRETS_ROOT="${SECRETS_ROOT:-}"
if [[ -z "$SECRETS_ROOT" ]]; then
  for candidate in /run/acer-mgmt/secrets "$DATA_ROOT/vault-agent/secrets"; do
    if [[ -d "$candidate" ]]; then
      SECRETS_ROOT="$candidate"
      break
    fi
  done
fi
SECRETS_ROOT="${SECRETS_ROOT:-/run/acer-mgmt/secrets}"
failed=0

pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*" >&2; failed=1; }

require_container() {
  local name="$1"
  if docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -qx true; then
    pass "container ${name} is running"
  else
    fail "container ${name} is not running"
  fi
}

echo '== Access plane =='
require_container teleport
if docker exec teleport tctl status >/dev/null 2>&1; then
  pass 'Teleport auth service responds'
else
  fail 'Teleport auth service does not respond'
fi
if docker exec teleport tctl apps ls >/dev/null 2>&1; then
  pass 'tctl apps ls succeeds'
else
  fail 'tctl apps ls fails'
fi

echo '== Identity and authorization =='
require_container keycloak
if docker exec keycloak-db psql -U keycloak -d keycloak -Atc \
  "select events_enabled || ',' || admin_events_enabled || ',' || admin_events_details_enabled from realm where name='mgmt'" \
  2>/dev/null | grep -qx 'true,true,false'; then
  pass 'Keycloak event configuration is enabled without admin representations'
else
  fail 'Keycloak event configuration is not true,true,false'
fi
if docker exec netbox /opt/netbox/venv/bin/python /opt/netbox/netbox/manage.py shell -c \
  "from users.models import User; u=User.objects.get(username='mgmt'); print(u.is_superuser)" \
  2>/dev/null | tail -n1 | grep -qx True; then
  pass 'NetBox mgmt OIDC account is administrator'
else
  fail 'NetBox mgmt OIDC account is not administrator'
fi

echo '== Native audit sources =='
require_container vault
if docker exec vault sh -lc 'VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true VAULT_TOKEN=$(cat /tmp/.vt 2>/dev/null || true); test -n "$VAULT_TOKEN" && vault audit list >/dev/null' 2>/dev/null; then
  pass 'vault audit list succeeds with the mounted verifier token'
else
  warn 'vault audit list requires an audit-read token; checking durable log files instead'
fi
for log_file in \
  "$DATA_ROOT/vault-audit/vault-audit.log" \
  "$DATA_ROOT/vault-audit-secondary/vault-audit-socket.log"; do
  [[ -s "$log_file" ]] && pass "Vault audit log exists: ${log_file}" || fail "Vault audit log missing: ${log_file}"
done
[[ -d "$DATA_ROOT/teleport/log" ]] && pass 'Teleport audit log directory exists' || fail 'Teleport audit log directory missing'

echo '== Audit collectors =='
if systemctl is-active --quiet acer-mgmt-filebeat-docker.service; then
  pass 'Docker/audit Filebeat collector is active'
else
  fail 'Docker/audit Filebeat collector is inactive'
fi
if sudo -n filebeat test config -c /etc/filebeat-docker/filebeat.yml >/dev/null 2>&1; then
  pass 'Docker/audit Filebeat configuration validates'
else
  fail 'Docker/audit Filebeat configuration does not validate'
fi
require_container logstash
require_container logstash-consumer
require_container elasticsearch

echo '== Wazuh host detection =='
if docker inspect -f '{{.State.Running}}' wazuh-manager 2>/dev/null | grep -qx true; then
  pass 'wazuh-manager is running'
else
  warn 'wazuh-manager is not deployed yet'
fi

echo '== Teleport application certificate coverage =='
tls_cert="$SECRETS_ROOT/security/teleport/tls.crt"
if [[ -r "$tls_cert" ]] && openssl x509 -in "$tls_cert" -noout -ext subjectAltName 2>/dev/null | grep -Fq "DNS:*.teleport.${BASE_DOMAIN}"; then
  pass "Teleport application certificate covers *.teleport.${BASE_DOMAIN}"
else
  fail "Teleport application certificate coverage is missing for *.teleport.${BASE_DOMAIN}"
fi

if (( failed )); then
  exit 1
fi
