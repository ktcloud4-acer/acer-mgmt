# Tailnet Central Ansible Orchestration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the removed Semaphore Runner bootstrap with mgmt-owned issuance, Tailscale device reconciliation, dynamic inventory, and a Semaphore Community Ansible task that installs the AIO's layer-40 Operator tooling.

**Architecture:** Vault keeps a dedicated mgmt-only OAuth client for issuing tagged AIO keys and renaming devices; AIOs never receive this client. Semaphore runs Ansible centrally, resolves an AIO by its `tag:aio-<team>` identity, connects over Tailnet SSH, and passes only a temporary team Operator credential file to the existing AIO checkout.

**Tech Stack:** Vault KV v2, Tailscale OAuth client-credentials/API v2, Semaphore Community, Ansible, SSH, Bash, jq, Helm, Kubernetes.

## Global Constraints

- Preserve `mgmt/tailscale/operators/<team>` and `mgmt/tailscale/bootstrap/<team>`; they are not Semaphore Runner resources.
- Do not recreate `mgmt/tailscale/task-credentials/*`, AppRoles, or Runner registration secrets.
- Store the dedicated enrollment OAuth pair only at `kv/mgmt/tailscale/aio-enrollment` and never render it into a Semaphore environment or AIO filesystem.
- Enrollment OAuth needs `auth_keys` and `devices:core` scopes and a parent tag that owns `tag:aio-ggg`, `tag:aio-khb`, `tag:aio-ljw`, `tag:aio-nmg`, and `tag:aio-oje`.
- Preserve every ScaleCart task/template/repository/environment.

---

### Task 1: Establish the external Tailnet policy prerequisite

**Files:**
- Create: `docs/runbooks/tailscale-aio-enrollment-2026-07-12.md`
- Create: `compose/config/tailscale/aio-teams.json`
- Test: `compose/tests/test-tailnet-central-orchestration.sh`

**Interfaces:**
- Consumes: the five fixed team slugs.
- Produces: the sole mapping from a team to `tag:aio-<team>` and `<team>-aio`.

- [ ] **Step 1: Write a failing contract test.**

Require five unique records with `team`, `aio_tag`, and `machine_name`; require the enrollment Vault path; reject secret literal prefixes. The expected NMG record is:

```json
{"team":"nmg","aio_tag":"tag:aio-nmg","machine_name":"nmg-aio"}
```

- [ ] **Step 2: Add the manifest and runbook.**

The runbook must require a Tailnet admin to create `tag:aio-enroller`, make it owner of the five AIO tags, and create a dedicated OAuth client restricted to `auth_keys` plus `devices:core` and the parent tag. It must state that the existing Operator OAuth client is not widened or reused.

- [ ] **Step 3: Run the failing-to-passing test and commit.**

Run: `bash compose/tests/test-tailnet-central-orchestration.sh`

Expected: `TAILNET_CENTRAL_ORCHESTRATION_CONTRACT=PASS`.

```bash
git add compose/config/tailscale docs/runbooks compose/tests/test-tailnet-central-orchestration.sh
git commit -m "feat: AIO Tailnet 팀 정책 정의"
```

### Task 2: Add mgmt-only Vault bootstrap and one-use key issuance

**Files:**
- Create: `compose/scripts/bootstrap-vault-tailscale-aio-enrollment.sh`
- Create: `compose/scripts/issue-tailscale-aio-authkey.sh`
- Modify: `compose/tests/test-tailnet-central-orchestration.sh`

**Interfaces:**
- Consumes: externally supplied `TAILSCALE_AIO_ENROLLMENT_CLIENT_ID` and `TAILSCALE_AIO_ENROLLMENT_CLIENT_SECRET` once, then Vault path `mgmt/tailscale/aio-enrollment`.
- Produces: one one-use, non-ephemeral, pre-authorized auth key for a manifest team on standard output; the key is never logged or written to disk by mgmt.

- [ ] **Step 1: Extend the contract test.**

Require the bootstrap script to write only `client_id` and `client_secret` at the dedicated path. Require issuance to use the OAuth token endpoint, `/api/v2/tailnet/-/keys`, `reusable:false`, `ephemeral:false`, `preauthorized:true`, the manifest tag, `umask 077`, and no key printing except its final standard-output handoff.

- [ ] **Step 2: Implement Vault bootstrap.**

Use the existing `/tmp/.vt` pattern inside the Vault container. Validate team-independent client variables, write the two fields to Vault, and output only `Tailscale AIO enrollment credential stored.`

- [ ] **Step 3: Implement one-use key issuance.**

The script accepts zero or one team argument. With no argument it prompts only for one of `ggg`, `khb`, `ljw`, `nmg`, or `oje`; it never prompts for a tag, hostname, Vault path, or OAuth field. It loads the matching tag and machine name from `aio-teams.json`, retrieves the OAuth pair from Vault in a temporary shell scope, exchanges them at `https://api.tailscale.com/api/v2/oauth/token`, and posts:

```json
{"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":false,"preauthorized":true,"tags":["tag:aio-nmg"]}}}}
```

It writes only the returned `key` field to stdout; diagnostics go to stderr and all temporary JSON/token files are removed by an EXIT trap. The script starts with `set -euo pipefail`; an invalid selection, missing Vault field, OAuth error, API error, or output-pipe failure exits nonzero.

- [ ] **Step 4: Run tests and shell validation, then commit.**

```bash
bash compose/tests/test-tailnet-central-orchestration.sh
bash -n compose/scripts/bootstrap-vault-tailscale-aio-enrollment.sh compose/scripts/issue-tailscale-aio-authkey.sh
git add compose/scripts compose/tests/test-tailnet-central-orchestration.sh
git commit -m "feat: AIO Tailnet 일회 가입 키 발급 추가"
```

### Task 3: Reconcile tagged devices into dynamic Ansible inventory

**Files:**
- Create: `compose/scripts/reconcile-tailscale-aio-devices.sh`
- Create: `compose/ansible/tailscale-aio-inventory.py`
- Modify: `compose/tests/test-tailnet-central-orchestration.sh`

**Interfaces:**
- Consumes: `aio-teams.json`, mgmt-only enrollment OAuth client, and the Tailscale devices API.
- Produces: a generated Ansible inventory group `aio_<team>` with `ansible_host` equal to the discovered Tailscale IP, plus a renamed machine `<team>-aio`.

- [ ] **Step 1: Extend the contract test.**

Require device lookup by tag, exactly one online device per selected team, the `POST /api/v2/device/:deviceID/name` endpoint, and dynamic inventory JSON shaped as:

```json
{"aio_nmg":{"hosts":["nmg-aio"],"vars":{"ansible_user":"ubuntu"}},"_meta":{"hostvars":{"nmg-aio":{"ansible_host":"100.64.0.10"}}}}
```

- [ ] **Step 2: Implement reconciliation and inventory.**

The reconciliation script exchanges its OAuth pair in memory, lists `tailnet/-/devices`, selects exactly one device with the manifest tag, renames it only if its name differs, and never changes tags. The Python inventory receives a non-secret JSON device snapshot from stdin, emits only the Ansible inventory schema, and rejects duplicate/missing team devices.

- [ ] **Step 3: Run tests and commit.**

```bash
bash compose/tests/test-tailnet-central-orchestration.sh
python3 -m py_compile compose/ansible/tailscale-aio-inventory.py
git add compose/scripts/reconcile-tailscale-aio-devices.sh compose/ansible compose/tests/test-tailnet-central-orchestration.sh
git commit -m "feat: 태그 기반 AIO Ansible 인벤토리 추가"
```

### Task 4: Add central Semaphore Community Ansible orchestration

**Files:**
- Create: `compose/ansible/tailscale-operator-bootstrap.yml`
- Create: `compose/scripts/reconcile-tailscale-operator-ansible-tasks.sh`
- Modify: `compose/stacks/cicd/semaphore/Dockerfile`
- Modify: `compose/stacks/cicd/semaphore/compose.yaml`
- Modify: `compose/stacks/security/vault-agent/config/agent.hcl`
- Modify: `compose/tests/test-tailnet-central-orchestration.sh`
- Delete: `compose/scripts/tailscale/semaphore-bootstrap-operator.sh`
- Delete: `compose/scripts/reconcile-tailscale-operator-tasks.sh`
- Delete: `compose/tests/test-aio-semaphore-runner.sh`

**Interfaces:**
- Consumes: a resolved Tailnet inventory, existing team Operator OAuth path, and each AIO checkout's `40-tailscale-k8s/install-operator.sh`.
- Produces: one serialized Community-compatible Ansible Semaphore template per team, without a Runner, Vault AppRole, or remote-runner Traefik endpoint.

- [ ] **Step 1: Extend the failing contract.**

Require Ansible and SSH client availability in the Semaphore image, Ansible inventory generation before the play, a temporary remote credentials file mode `0600`, `no_log: true` for credential transfer, and an always cleanup block. Require removal of `SEMAPHORE_USE_REMOTE_RUNNER`, `/api/internal/runners` routing, and `SEMAPHORE_RUNNER_REGISTRATION_TOKEN` rendering.

- [ ] **Step 2: Implement the playbook.**

The play selects `aio_{{ team }}`, reads `mgmt/tailscale/operators/{{ team }}` only through mgmt-local Vault access, writes a temporary JSON file with owner-only mode on the target, executes `/home/ubuntu/acer-aio/40-tailscale-k8s/install-operator.sh` with the target kubeconfig, and removes the temporary file in an `always` block. It must not copy any Vault token or recovery kubeconfig to the AIO.

- [ ] **Step 3: Replace the Semaphore task reconciler.**

Create/update a single Ansible template named `Bootstrap Tailscale Operator` in each team project. The template references the central mgmt checkout and dynamic inventory generation, is serialized, and does not create a team environment containing secret fields.

- [ ] **Step 4: Remove Runner-only server configuration.**

Delete the Remote Runner environment setting/router, both Vault Agent Runner-token template lines, and the obsolete Runner tests. Retain native OIDC, ScaleCart resources, and the general Semaphore service.

- [ ] **Step 5: Run static and Compose verification, then commit.**

```bash
bash compose/tests/test-tailnet-central-orchestration.sh
bash compose/tests/test-semaphore-native-oidc.sh
docker compose --env-file compose/.env -f compose/stacks/cicd/semaphore/compose.yaml config >/dev/null
git add -A compose
git commit -m "feat: 중앙 Ansible Tailnet 오케스트레이션 전환"
```

### Task 5: Deploy and prove NMG end-to-end

**Files:**
- Modify: `README.md`
- Modify: `docs/runbooks/tailscale-aio-enrollment-2026-07-12.md`

**Interfaces:**
- Consumes: Tailnet policy/OAuth prerequisite, Vault enrollment credential, NMG AIO layer 05, and the reconciled Semaphore template.
- Produces: a named `nmg-aio` device and a successful central Semaphore task without a Runner.

- [ ] **Step 1: Store the dedicated OAuth credential in Vault.**

Run the new bootstrap script only from mgmt with terminal-only variables. Verify with `vault kv get` field names only: `client_id`, `client_secret`.

- [ ] **Step 2: Issue and securely deliver the NMG one-use key.**

Pipe the issuing script directly into the documented `sudo install` command over the existing bootstrap SSH path. Do not display or save the key in a terminal transcript.

- [ ] **Step 3: Run layer 05, reconcile NMG, and prove inventory.**

Verify exactly one `tag:aio-nmg` device, its renamed machine `nmg-aio`, one generated Ansible host, and Tailnet SSH from mgmt to that host.

- [ ] **Step 4: Reconcile and run the NMG Semaphore task.**

Verify a successful task log, Helm release readiness, Tailscale Operator Deployment readiness, and preserved ScaleCart template. Confirm AIO contains no `/run/acer-bootstrap/tailscale-operator.json` after the task.

- [ ] **Step 5: Commit runbook evidence and execute integration review.**

```bash
git add README.md docs/runbooks/tailscale-aio-enrollment-2026-07-12.md
git commit -m "docs: NMG Tailnet 중앙 실행 검증 추가"
```
