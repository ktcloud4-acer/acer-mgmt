# Native Teleport SSH Service for acer-mgmt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enroll `acer-mgmt` as a persistent, SELinux-confined native Teleport SSH node and verify real `user1` access without changing OpenSSH.

**Architecture:** Keep the central Auth/Proxy/App services in Docker. Install an SSH-only Teleport 18.9.2 agent on the host as `teleport-node.service`; it maintains an outbound reverse tunnel to `teleport.imcherry5778.xyz:3080` and does not expose an inbound node port.

**Tech Stack:** Teleport Community 18.9.2, Rocky Linux 9, systemd, SELinux, Bash, Docker Compose.

## Global Constraints

- Remove every Agentless resource, `sshd` directive, temporary artifact, and design file before Native installation.
- Do not change `sshd_config`, port 22, the existing direct SSH path, or current Teleport login permissions.
- Use only the official 18.9.2 tarball and its verified SHA-256.
- Keep join tokens in root-only files and remove them after the first successful heartbeat.
- Keep SELinux enforcing and require the `teleport_ssh_t` domain.
- Use `TELEPORT_ADD_KEYS_TO_AGENT=no` for all local `tsh` checks.

---

### Task 1: Add a failing end-to-end verifier

**Files:**
- Create: `compose/scripts/verify-teleport-node.sh`

**Interfaces:**
- Consumes: workstation `tsh`, direct SSH alias `acer-mgmt`, central `tctl` in the Docker container.
- Produces: exit 0 only when the native node, SELinux domain, user session, audit path, and direct SSH safety path are all healthy.

- [x] Write the verifier with explicit failure messages.
- [x] Run `bash compose/scripts/verify-teleport-node.sh` before implementation.
- [x] Confirm RED: it fails because `teleport-node.service` and native node are absent.

### Task 2: Add the SSH-only config, systemd unit, and installer

**Files:**
- Create: `compose/stacks/security/teleport/node/acer-mgmt.yaml`
- Create: `compose/systemd/teleport-node.service`
- Create: `compose/scripts/install-teleport-node.sh`

**Interfaces:**
- Consumes: a root-readable join-token file path.
- Produces: `/usr/local/bin/teleport`, `/etc/teleport-node.yaml`, `/var/lib/teleport-node`, installed `teleport_ssh` SELinux policy, and enabled `teleport-node.service`.

- [x] Add an explicit SSH-only config with node name `acer-mgmt`, labels `env=mgmt,owner=infra`, data dir `/var/lib/teleport-node`, and token path `/var/lib/teleport-node/join.token`.
- [x] Add a systemd service that starts with `--enable-selinux --ensure-selinux-enforcing`.
- [x] Add a transactional, pinned-checksum installer that validates a root-only token, installs `selinux-policy-devel` and the official SELinux module, requires a current-invocation tunnel for the exact host UUID, revokes the Auth Service token, removes both token files, and proves a fresh restart without them.
- [x] Run `bash -n` on both scripts and `git diff --check`.

### Task 3: Install and enroll the live acer-mgmt node

**Files:**
- Runtime create: `/etc/teleport-node.yaml`
- Runtime create: `/etc/systemd/system/teleport-node.service`
- Runtime create: `/var/lib/teleport-node`
- Runtime create then delete: `/var/lib/teleport-node/join.token`

**Interfaces:**
- Consumes: a 10-minute node token created inside the central Teleport container.
- Produces: a native node heartbeat and reverse tunnel.

- [x] Reconfirm Agentless absence and direct SSH health.
- [x] Generate a 10-minute token into a root-only file without printing it.
- [x] copy the repository-owned config, service, and scripts to the live checkout.
- [x] Run the installer using the token file.
- [x] Confirm the service restarts successfully after token deletion.

### Task 4: Reach GREEN with live access and audit verification

**Files:**
- Test: `compose/scripts/verify-teleport-node.sh`

**Interfaces:**
- Consumes: the running native node.
- Produces: evidence for every acceptance criterion.

- [x] Run the verifier and confirm GREEN.
- [x] Run a fresh `tsh ssh user1@acer-mgmt` command and verify user and hostname.
- [x] Verify `teleport_ssh_t`, `Enforcing`, current-invocation reverse-tunnel logs, absence of an inbound 3022 listener, exact node ID/labels/version, structured session records, direct SSH, and complete Agentless resource/host cleanup.
- [x] Restart `teleport-node.service` a second time with no token and rerun the verifier.

### Task 5: Document the operating model and recovery

**Files:**
- Modify: `compose/stacks/security/teleport/README.md`
- Modify: `docs/runbooks/teleport-access-plane-2026-07-10.md`

**Interfaces:**
- Consumes: verified runtime paths and commands from Tasks 3-4.
- Produces: beginner-friendly Native versus Agentless explanation and exact recovery commands.

- [x] Document component flow, service/config/data paths, token lifecycle, Bitwarden agent setting, verification, restart, and rollback.
- [x] Remove obsolete long-lived 2160-hour node-token examples.
- [x] Run secret-pattern scans and `git diff --check`.

### Task 6: Review, publish, merge, and synchronize

**Files:**
- Review all intended Teleport files; exclude unrelated `.claude/` content.

**Interfaces:**
- Consumes: complete verification output and clean scoped diff.
- Produces: committed branch, pushed GitLab merge request, merged `main`, synchronized local/live/remote state, and cleaned source branch.

- [ ] Request independent code review and resolve Critical/Important findings.
- [ ] Re-run the complete verifier and repository checks.
- [ ] Commit only intended files, rebase on current `origin/main`, push, open a GitLab merge request, merge it to `main`, and delete the source branch.
- [ ] Synchronize workstation and live host checkouts to remote `main` without discarding unrelated user files.
- [ ] Report `git status`, HEAD, remote ref, service health, node heartbeat, real `tsh ssh`, direct SSH, and audit evidence.
