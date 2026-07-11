# Native Teleport SSH Service for acer-mgmt

## Goal

Run a persistent, SELinux-confined Teleport SSH Service on the `acer-mgmt`
host and enroll it as the native node `acer-mgmt` in the existing Docker-based
Teleport cluster. Users connect with `tsh ssh user1@acer-mgmt`; direct
OpenSSH on port 22 remains a break-glass path.

## Architecture

The Docker container remains the central Auth, Proxy, and Application access
plane. Its `ssh_service` stays disabled because enabling it would expose the
container, not the host.

The host runs a separate Teleport 18.9.2 process:

```text
tsh -> Teleport Proxy :3080 -> outbound reverse tunnel -> host teleport-node
                                                    -> user1 shell
```

The node agent dials the Proxy outbound and stores its host identity under
`/var/lib/teleport-node`. The initial join token is short-lived, file-backed
under the SELinux-labeled node data directory, used once, and removed after
enrollment.

## Repository-owned files

- `compose/stacks/security/teleport/node/acer-mgmt.yaml`: SSH-only node config.
- `compose/systemd/teleport-node.service`: persistent systemd unit with
  SELinux enforcement flags.
- `compose/scripts/install-teleport-node.sh`: checksum-verified installation,
  SELinux policy setup, bootstrap, and enrollment.
- `compose/scripts/verify-teleport-node.sh`: end-to-end acceptance test.
- `compose/stacks/security/teleport/README.md`: operator explanation.
- `docs/runbooks/teleport-access-plane-2026-07-10.md`: rollout and recovery.

## Security decisions

- Use the official Teleport Community 18.9.2 Linux tarball with its SHA-256
  pinned in the installer. Teleport supports its SSH Service SELinux module
  only with the tarball installation path.
- Keep SELinux enforcing and start with both `--enable-selinux` and
  `--ensure-selinux-enforcing`.
- Enable only `ssh_service`; disable Auth, Proxy, Kubernetes, App, Database,
  and Discovery services in the host config.
- Run in tunnel mode without an inbound host listener. `proxy_server` makes the
  node dial the Proxy outbound; Teleport logs that it ignores the normal 3022
  listener setting. Port 22 remains the existing break-glass route.
- Keep the current Teleport roles and allowed logins (`user1`, `ubuntu`,
  `root`) unchanged. Verify the rollout as non-root `user1`.
- Never store a join token in Git, command history, reports, or the static
  configuration. The installer accepts a root-only token file, copies it to
  `/var/lib/teleport-node/join.token` for the first join, then deletes both the
  supplied token file and the copied bootstrap token after revoking the
  matching Auth Service token.
- Treat installation as a transaction. Any failure after deployment begins
  revokes and deletes the credential, stops a newly changed service, restores
  the prior binary/config/unit, node data, SELinux module, and enabled/active
  state, and removes node state created by that failed attempt.
- Set `TELEPORT_ADD_KEYS_TO_AGENT=no` for local validation so Bitwarden remains
  the normal `SSH_AUTH_SOCK` provider without receiving Teleport ephemeral
  keys.

## Native versus Agentless OpenSSH

| Concern | Native SSH Service | Agentless OpenSSH |
|---|---|---|
| Server process | Persistent `teleport` agent | Existing `sshd` |
| Host config | `/etc/teleport-node.yaml` | `sshd_config`, Teleport CA, host certificate |
| Network path | Outbound reverse tunnel | Proxy directly dials port 22 |
| Inbound host port | None in this tunnel-mode deployment | OpenSSH on 22 |
| Session features | Full native recording, sharing, labels | Proxy recording; reduced advanced features |
| Host identity | Agent identity in `/var/lib/teleport-node` | OpenSSH host certificate |
| SELinux | `teleport_ssh_t` policy module | Existing `sshd_t` policy plus certificate file labels |
| Removal | Stop agent and delete its config/data | Undo `sshd_config`, CA, certificate, node resource |

Native does not modify `sshd_config`, `TrustedUserCAKeys`, or OpenSSH host
keys. This removes the certificate-labeling failure encountered during the
Agentless pilot and preserves the existing SSH daemon independently.

## Acceptance criteria

1. No Agentless node, `sshd_config` include, TrustedUserCAKeys, host
   certificate, or `/root/teleport-agentless-pilot` residue remains.
2. `teleport-node.service` is enabled and active after its current systemd
   invocation establishes a reverse-tunnel keepalive for the exact host UUID,
   including after a fresh restart without a token or inbound 3022 listener.
3. The Teleport process runs in SELinux domain `teleport_ssh_t` while SELinux
   is enforcing.
4. `tctl nodes ls` and `tsh ls` report exactly one native `acer-mgmt` node with
   `env=mgmt` and `owner=infra`.
5. `tsh ssh user1@acer-mgmt` returns `user1` and hostname `acer-mgmt`.
6. Teleport's structured session records contain a newly correlated native
   session for the tested user, login, hostname, and node UUID.
7. Existing direct SSH returns `root`, and `sshd` remains active on port 22.
8. Repository documentation explains Native and Agentless data flow and config
   differences without including secret values.

## Rollback

Disable and remove `teleport-node.service`, remove `/etc/teleport-node.yaml`
and `/var/lib/teleport-node`, uninstall the `teleport_ssh` SELinux module, and
remove the native node resource if its heartbeat has not expired. Rollback
does not touch `sshd`, because Native enrollment never modifies it.
