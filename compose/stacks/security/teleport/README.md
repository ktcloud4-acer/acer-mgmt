# Teleport access plane

Teleport replaces shared SSH keys and scattered kubeconfigs with SSO-backed,
short-lived access certificates and auditable sessions.

## Runtime boundary

- Control plane: `acer-mgmt` Docker Compose.
- Public address: `teleport.imcherry5778.xyz`.
- DNS: AdGuard rewrite must map `teleport.imcherry5778.xyz` to the
  `acer-mgmt` Tailscale IP.
- Listening ports: `${TAILSCALE_IP}:3080`, `${TAILSCALE_IP}:3023`,
  `${TAILSCALE_IP}:3024`, `${TAILSCALE_IP}:3026`.
- Persistent data: `${DATA_ROOT}/teleport`.
- Native `acer-mgmt` SSH Service: host systemd unit
  `teleport-node.service`, config `/etc/teleport-node.yaml`, and identity data
  `/var/lib/teleport-node`.
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

If the container repeatedly restarts with `teleport: error: unexpected teleport`
or `teleport: error: unexpected start`, the compose command is overriding the
distroless image entrypoint incorrectly. This image already starts
`teleport start -c /etc/teleport/teleport.yaml`, so the service should not set a
custom command unless the image entrypoint changes.

## How to read this setup

Teleport has one central server and multiple resources behind it:

- `auth_service`: the source of truth for users, roles, short-lived certs, and
  audit events.
- `proxy_service`: the public entrypoint that users reach with a browser or
  `tsh`.
- `app_service`: publishes internal mgmt apps such as Grafana, Kibana,
  Prometheus, Alertmanager, Keycloak, Vault, and NetBox through Teleport.
- Kubernetes agents: run in each target cluster and reverse-connect to the
  proxy with a Vault-backed join token.
- SSH node agents: run on hosts such as `acer-mgmt` and `acer-aio-khb` when
  host login through `tsh ssh` is needed.

User flow:

```bash
export TELEPORT_ADD_KEYS_TO_AGENT=no
tsh login --proxy=teleport.imcherry5778.xyz:3080 --user=admin \
  --mfa-mode=auto --add-keys-to-agent=no
tsh apps ls
tsh kube ls
tsh ssh user1@acer-mgmt
```

`TELEPORT_ADD_KEYS_TO_AGENT=no` keeps Teleport's short-lived keys under
`~/.tsh` instead of asking the Bitwarden SSH agent to import them. Bitwarden
can still remain the default `SSH_AUTH_SOCK` provider.

The central container being healthy only means the access plane is online. SSH
hosts and Kubernetes clusters appear only after their agents have joined.

## Native SSH on `acer-mgmt`

The central Docker service and the host SSH Service have deliberately separate
configs:

| Component | Repository config | Runtime config | Enabled services |
|---|---|---|---|
| Central access plane | `config/teleport.yaml` | `/etc/teleport/teleport.yaml` in the container | Auth, Proxy, App |
| Host node | `node/acer-mgmt.yaml` | `/etc/teleport-node.yaml` on the host | SSH only |
| Break-glass OpenSSH | Not managed here | `/etc/ssh/sshd_config` | Existing `sshd` on port 22 |

The host process dials the Proxy outbound and handles Teleport SSH streams over
that reverse tunnel:

```text
tsh -> Proxy :3080 -> outbound reverse tunnel -> teleport-node -> user1 shell
```

There is no inbound Teleport node port in this deployment. In tunnel mode the
normal 3022 listener is not opened. The unchanged OpenSSH port 22 is a separate
break-glass path.

This is different from Agentless OpenSSH. Agentless has no host Teleport
process; the Proxy dials `sshd` on port 22 and the host must trust a Teleport
user CA and present an OpenSSH host certificate. Native mode instead owns its
identity under `/var/lib/teleport-node`, supports the full Teleport session
path, and does not change `sshd_config`, `TrustedUserCAKeys`, or OpenSSH keys.

Install or rebuild the verified `acer-mgmt` node from a direct root shell:

```bash
cd /home/user1/acer-mgmt/compose
umask 077
docker exec teleport tctl tokens add --type=node --ttl=10m --format=text \
  > /root/teleport-native-node.token
bash scripts/install-teleport-node.sh /root/teleport-native-node.token
```

The installer pins and verifies the Teleport 18.9.2 tarball SHA-256, installs
the official SSH Service SELinux policy, and requires a reverse-tunnel
keepalive from the current systemd invocation for the exact host UUID. It then
revokes the Auth Service token, deletes both token files, and proves a fresh
token-free restart. It requires SELinux to be enforcing. On failure it revokes
and deletes the credential, restores the prior binary/config/unit and service
state, restores prior node data and the `teleport_ssh` SELinux module, and
removes only node state created by that failed attempt.

Run the end-to-end verifier from a logged-in workstation:

```bash
cd /home/imcherry/projects/ktcloud4-acer/acer-mgmt
TELEPORT_ADD_KEYS_TO_AGENT=no bash compose/scripts/verify-teleport-node.sh
```

The verifier correlates a structured Teleport session record by time, Teleport
user, login, native node UUID, and hostname. It also requires zero Agentless
node resources and no Agentless OpenSSH include, CA, or host-certificate
artifacts.

Useful host checks:

```bash
systemctl is-enabled teleport-node.service
systemctl is-active teleport-node.service
ps -eZ | grep teleport_ssh_t
journalctl -u teleport-node.service -b --no-pager | grep 'tunnel mode'
test -z "$(ss -H -ltn 'sport = :3022')"
test ! -e /var/lib/teleport-node/join.token
```

Restart recovery uses the stored host identity and does not need a token:

```bash
systemctl restart teleport-node.service
```

For complete removal, follow the rollback section in
`docs/runbooks/teleport-access-plane-2026-07-10.md`. Native rollback removes
only the host Teleport service, identity, and node resource; it does not touch
OpenSSH.

## Bootstrap

1. Create a first break-glass local admin:

   ```bash
   docker exec teleport tctl users add admin --roles=editor,access --logins=user1,ubuntu,root
   ```

   If the link should not be printed into a shared terminal, redirect it to a
   root-only file on `acer-mgmt`:

   ```bash
   docker exec teleport tctl users add admin --roles=editor,access --logins=user1,ubuntu,root \
     >/root/teleport-admin-invite.txt
   chmod 600 /root/teleport-admin-invite.txt
   ```

2. Optional: configure Keycloak OIDC when running Teleport Enterprise or HCP:

   ```bash
   bash stacks/security/teleport/scripts/apply-keycloak-oidc.sh
   ```

3. Create Kubernetes join tokens and store them in Vault:

   ```bash
   docker exec teleport tctl tokens add --type=kube --ttl=2160h
   ```

   Store Kubernetes join tokens at:

   ```text
   kv/apps/teleport-agent/<cluster>
     join_token
   ```

   Enroll native SSH hosts with short-lived, one-time files as documented in
   **Native SSH on `acer-mgmt`**. Do not store node tokens in Git or Vault.

## Target model

- `tsh ssh user1@acer-mgmt` replaces direct `ssh -i acer.pem user1@acer-mgmt`.
- `tsh ssh ubuntu@acer-aio-khb` replaces direct
  `ssh -i acer.pem ubuntu@172.16.8.10`.
- `tsh kube login <cluster>` replaces raw shared kubeconfigs.
- Teleport audit events and container logs are collected by the existing ELK
  pipeline through Filebeat.
