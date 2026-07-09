# Wazuh security stack

This stack runs the central Wazuh components on `acer-mgmt`:

- `wazuh-manager`
- `wazuh-indexer`
- `wazuh-dashboard`

Kubernetes and host endpoints run Wazuh agents only. Do not deploy the central
Wazuh components into `acer-aio` or team clusters.

## Runtime boundary

- Dashboard ingress: `https://wazuh.${BASE_DOMAIN}` through Traefik.
- Agent communication: `${TAILSCALE_IP}:1514/tcp`.
- Agent enrollment: `${TAILSCALE_IP}:1515/tcp`.
- Wazuh API: `${TAILSCALE_IP}:55000/tcp`.
- Persistent data: `${DATA_ROOT}/wazuh`.
- Secrets: `/run/acer-mgmt/secrets/security/wazuh.env`, rendered by Vault Agent.
- Enrollment password file:
  `/run/acer-mgmt/secrets/security/wazuh-authd.pass`, rendered by Vault Agent
  and mounted to `/var/ossec/etc/authd.pass`.

## Required Vault-rendered env

```bash
WAZUH_INDEXER_USERNAME=admin
WAZUH_INDEXER_PASSWORD=...
WAZUH_DASHBOARD_USERNAME=kibanaserver
WAZUH_DASHBOARD_PASSWORD=...
WAZUH_API_USERNAME=wazuh-wui
WAZUH_API_PASSWORD=...
WAZUH_AGENT_ENROLLMENT_PASSWORD=...
```

Do not put real values in `../.env`, stack-local `.env`, or Git.

## Certificates

The official Wazuh Docker deployment requires indexer/dashboard/manager
certificates under `config/wazuh_indexer_ssl_certs/`. This directory is ignored
except for `.gitkeep`.

Generate the certs from the official `wazuh-docker` `v4.14.6` tooling, copy only
the generated runtime files to the live host, and keep private keys out of Git.

Expected files:

```text
admin-key.pem
admin.pem
root-ca-manager.pem
root-ca.pem
wazuh.dashboard-key.pem
wazuh.dashboard.pem
wazuh.indexer-key.pem
wazuh.indexer.pem
wazuh.manager-key.pem
wazuh.manager.pem
```

## Start

```bash
cd /home/user1/acer-mgmt/compose
docker compose --env-file ../.env \
  --env-file /run/acer-mgmt/secrets/security/wazuh.env \
  -f stacks/security/wazuh/compose.yaml config

docker compose --env-file ../.env \
  --env-file /run/acer-mgmt/secrets/security/wazuh.env \
  -f stacks/security/wazuh/compose.yaml up -d
```

## Verify

```bash
docker compose --env-file ../.env \
  --env-file /run/acer-mgmt/secrets/security/wazuh.env \
  -f stacks/security/wazuh/compose.yaml ps

curl -kfsS https://127.0.0.1:5601/api/status
curl -kfsS https://127.0.0.1:9200
```

After the central stack is healthy, enroll endpoints in this order:

1. `acer-mgmt` host agent.
2. `acer-aio` host agent.
3. `ggg` Kubernetes agent DaemonSet.
4. Remaining team Kubernetes clusters.
