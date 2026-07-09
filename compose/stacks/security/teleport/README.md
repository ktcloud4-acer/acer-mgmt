# Teleport access plane

Teleport replaces shared SSH keys and scattered kubeconfigs with SSO-backed,
short-lived access certificates and auditable sessions.

## Runtime boundary

- Control plane: `acer-mgmt` Docker Compose.
- Public address: `teleport.imcherry5778.xyz`.
- Listening ports: `${TAILSCALE_IP}:3080`, `${TAILSCALE_IP}:3023`,
  `${TAILSCALE_IP}:3024`, `${TAILSCALE_IP}:3026`.
- Persistent data: `${DATA_ROOT}/teleport`.
- TLS material: `/run/acer-mgmt/secrets/security/teleport/tls.crt` and
  `/run/acer-mgmt/secrets/security/teleport/tls.key`, rendered by Vault Agent.
- Optional Enterprise/HCP SSO env:
  `/run/acer-mgmt/secrets/security/teleport.env`, rendered by Vault Agent.

Teleport intentionally uses separate Teleport proxy ports instead of Traefik
HTTPS termination. This preserves Teleport's SSH, reverse tunnel, and
Kubernetes protocols without making Traefik responsible for ALPN routing.

## Start

```bash
cd /home/user1/acer-mgmt/compose
docker compose --env-file ../.env \
  -f stacks/security/teleport/compose.yaml config

docker compose --env-file ../.env \
  -f stacks/security/teleport/compose.yaml up -d
```

## Bootstrap

1. Create a first break-glass local admin:

   ```bash
   docker exec teleport tctl users add admin --roles=editor,access --logins=user1,ubuntu,root
   ```

2. Optional: configure Keycloak OIDC when running Teleport Enterprise or HCP:

   ```bash
   bash stacks/security/teleport/scripts/apply-keycloak-oidc.sh
   ```

3. Create join tokens for agents and store them in Vault:

   ```bash
   docker exec teleport tctl tokens add --type=kube --ttl=2160h
   docker exec teleport tctl tokens add --type=node --ttl=2160h
   ```

   Store Kubernetes join tokens at:

   ```text
   kv/apps/teleport-agent/<cluster>
     join_token
   ```

   Store host join tokens out of Git and enroll hosts with the host-agent
   runbook.

## Target model

- `tsh ssh user1@acer-mgmt` replaces direct `ssh -i acer.pem user1@acer-mgmt`.
- `tsh ssh ubuntu@acer-aio-khb` replaces direct
  `ssh -i acer.pem ubuntu@172.16.8.10`.
- `tsh kube login <cluster>` replaces raw shared kubeconfigs.
- Teleport audit events and container logs are collected by the existing ELK
  pipeline through Filebeat.
