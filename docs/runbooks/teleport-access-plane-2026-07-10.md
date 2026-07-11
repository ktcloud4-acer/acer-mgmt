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

`acer-mgmt` uses a Native Teleport SSH Service, not Agentless OpenSSH. These
paths remain separate:

| Path | Process and config | Network path |
|---|---|---|
| Native Teleport | `teleport-node.service`, `/etc/teleport-node.yaml` | Host dials the Proxy outbound; no inbound 3022 listener |
| Agentless OpenSSH | `sshd`, `sshd_config`, Teleport CA and host certificate | Proxy dials host port 22 |
| Direct break-glass | Existing `sshd` and keys | Operator dials host port 22 |

Native is the selected implementation. Do not add `TrustedUserCAKeys`, a
Teleport OpenSSH host certificate, or an Agentless node resource. The central
Docker config keeps `ssh_service.enabled: false`; the host config enables only
the SSH Service.

From a direct root shell on `acer-mgmt`, create a ten-minute token without
printing it and run the repository-owned installer:

```bash
cd /home/user1/acer-mgmt/compose
umask 077
docker exec teleport tctl tokens add --type=node --ttl=10m --format=text \
  > /root/teleport-native-node.token
bash scripts/install-teleport-node.sh /root/teleport-native-node.token
```

The installer pins Teleport 18.9.2 and its SHA-256, installs the official
`teleport_ssh` SELinux module, applies the required file labels, and requires a
current-invocation reverse-tunnel keepalive for the exact UUID in
`/var/lib/teleport-node/host_uuid`. It revokes the Auth Service token, removes
both token files, and proves a fresh token-free restart. If installation fails,
it revokes/deletes the credential and restores the prior binary, config, unit,
service state, node data directory, and `teleport_ssh` SELinux module.

Validate from the workstation while retaining Bitwarden as `SSH_AUTH_SOCK`:

```bash
export TELEPORT_ADD_KEYS_TO_AGENT=no
tsh login --proxy=teleport.imcherry5778.xyz:3080 --user=admin \
  --mfa-mode=auto --add-keys-to-agent=no
cd /home/imcherry/projects/ktcloud4-acer/acer-mgmt
bash compose/scripts/verify-teleport-node.sh
```

The verifier checks service persistence, SELinux `teleport_ssh_t`, the current
systemd invocation's reverse tunnel, no 3022 listener, the exact node UUID and
labels, real `user1` login, a correlated structured session record, the
unchanged direct SSH path, and complete Agentless cleanup.

Routine restart and diagnosis:

```bash
systemctl restart teleport-node.service
systemctl status teleport-node.service --no-pager
getenforce
ps -eZ | grep teleport_ssh_t
journalctl -u teleport-node.service -b --no-pager | grep 'tunnel mode'
docker exec teleport tctl nodes ls
test ! -e /root/teleport-native-node.token
test ! -e /var/lib/teleport-node/join.token
```

If a rebuild is required, generate a new ten-minute token and rerun the
installer. Never restore the deleted bootstrap token. Keep `acer.pem` only as
a break-glass credential in Vault.

### Roll back the native node

Run from a direct root shell. Capture the node resource ID before removing its
local identity, then remove only the Native SSH Service artifacts:

```bash
node_id="$(docker exec teleport tctl nodes ls --format=json \
  | jq -r '.[] | select(.spec.hostname == "acer-mgmt" and ((.sub_kind // "") != "openssh")) | .metadata.name')"

systemctl disable --now teleport-node.service
rm -f /etc/systemd/system/teleport-node.service /etc/teleport-node.yaml
rm -rf /var/lib/teleport-node
rm -f /usr/local/bin/teleport /run/teleport.pid
semodule -r teleport_ssh
systemctl daemon-reload

test -z "${node_id}" || docker exec teleport tctl rm "node/${node_id}"
unset node_id
systemctl is-active sshd
```

Do not remove `sshd_config`, port 22 keys, or direct SSH access during this
rollback; Native enrollment never changed them.

## User commands

```bash
export TELEPORT_ADD_KEYS_TO_AGENT=no
tsh login --proxy=teleport.imcherry5778.xyz:3080 --user=admin \
  --mfa-mode=auto --add-keys-to-agent=no
tsh ssh user1@acer-mgmt
tsh ssh ubuntu@acer-aio-khb
tsh kube ls
tsh kube login khb
tsh kubectl get nodes
```
