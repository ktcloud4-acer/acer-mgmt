# Teleport access plane runbook

This runbook replaces shared `acer.pem` SSH and raw kubeconfigs with Teleport.
Boundary is not introduced in this phase. It remains a later option for
DB/TCP targets if Vault-backed dynamic credentials become a hard requirement.

## Prerequisites

- `teleport.imcherry5778.xyz` resolves to the `acer-mgmt` Tailscale IP.
- Vault Agent renders:
  - `/run/acer-mgmt/secrets/security/teleport/tls.crt`
  - `/run/acer-mgmt/secrets/security/teleport/tls.key`
- Optional, if using Teleport Enterprise/HCP SSO: Keycloak has a confidential OIDC client:
  - client id: `teleport`
  - redirect URI: `https://teleport.imcherry5778.xyz:3080/v1/webapi/oidc/callback`
  - group claim includes `platform-admin`, `platform-editor`, or `platform-viewer`

## Start central Teleport

```bash
cd /home/user1/acer-mgmt/compose
docker compose --env-file ../.env \
  -f stacks/security/teleport/compose.yaml up -d

docker exec teleport tctl status
```

Create a temporary break-glass admin:

```bash
docker exec teleport tctl users add admin --roles=editor,access --logins=user1,ubuntu,root
```

Optional, if the license allows SSO, apply Keycloak OIDC:

```bash
cd /home/user1/acer-mgmt/compose
bash stacks/security/teleport/scripts/apply-keycloak-oidc.sh
```

## Join Kubernetes clusters

For each cluster, create a kube join token and store it in Vault:

```bash
docker exec teleport tctl tokens add --type=kube --ttl=2160h
vault kv put kv/apps/teleport-agent/khb join_token='<token>'
vault kv put kv/apps/teleport-agent/ggg join_token='<token>'
vault kv put kv/apps/teleport-agent/ljw join_token='<token>'
vault kv put kv/apps/teleport-agent/nmg join_token='<token>'
vault kv put kv/apps/teleport-agent/oje join_token='<token>'
```

Each cluster must have Vault Kubernetes auth:

```text
mount: kubernetes-<cluster>
role: teleport-agent
policy: read kv/data/apps/teleport-agent/<cluster>
```

Apply the Argo CD Applications:

```bash
kubectl apply -f argocd/teleport-agent-secrets-ggg-application.yaml \
  -f argocd/teleport-kube-agent-ggg-application.yaml \
  -f argocd/teleport-agent-secrets-khb-application.yaml \
  -f argocd/teleport-kube-agent-khb-application.yaml \
  -f argocd/teleport-agent-secrets-ljw-application.yaml \
  -f argocd/teleport-kube-agent-ljw-application.yaml \
  -f argocd/teleport-agent-secrets-nmg-application.yaml \
  -f argocd/teleport-kube-agent-nmg-application.yaml \
  -f argocd/teleport-agent-secrets-oje-application.yaml \
  -f argocd/teleport-kube-agent-oje-application.yaml
```

Down clusters can remain `Unknown` or `Missing`; Argo CD will converge when
their API server returns.

## Join SSH hosts

Create node join tokens:

```bash
docker exec teleport tctl tokens add --type=node --ttl=2160h
```

Install a Teleport node service on each host using that token and the proxy:

```bash
sudo teleport configure \
  --roles=node \
  --token='<node-token>' \
  --proxy=teleport.imcherry5778.xyz:3080 \
  --nodename=acer-mgmt \
  --output=/etc/teleport.yaml
sudo systemctl enable --now teleport
```

For `acer-aio(khb)`, use:

```bash
sudo teleport configure \
  --roles=node \
  --token='<node-token>' \
  --proxy=teleport.imcherry5778.xyz:3080 \
  --nodename=acer-aio-khb \
  --output=/etc/teleport.yaml
sudo systemctl enable --now teleport
```

After validation, keep `acer.pem` only as a break-glass credential in Vault.

## User commands

```bash
tsh login --proxy=teleport.imcherry5778.xyz:3080
tsh ssh user1@acer-mgmt
tsh ssh ubuntu@acer-aio-khb
tsh kube ls
tsh kube login khb
tsh kubectl get nodes
```
