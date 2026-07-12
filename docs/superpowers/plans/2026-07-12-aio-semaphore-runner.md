# AIO Semaphore Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Register a persistent AIO Semaphore Runner and run NMG Tailscale Operator bootstrap without AIO Tailnet enrollment or mgmt-to-AIO SSH.

**Architecture:** Semaphore on mgmt enables remote runners and obtains its registration token from Vault Agent. A pinned tool-bearing Runner container on AIO registers once over existing administrator SSH, then receives NMG jobs over HTTPS. The job accesses Vault through `vault.imcherry5778.xyz` with task-scoped AppRole credentials and connects directly to the NMG Kubernetes API from AIO.

**Tech Stack:** Semaphore UI v2.18.25, Docker Compose, HashiCorp Vault KV v2/AppRole, Kubernetes kubectl v1.35.6, Helm v3.19.0.

## Global Constraints

- Do not store a registration token, Vault token, OAuth secret, kubeconfig, Tailscale key, or SSH private key in Git.
- Pin Runner base image to `semaphoreui/semaphore:v2.18.25` and Kubernetes tools to their current mgmt pins.
- AIO Runner only needs outbound TLS to Semaphore and Vault; do not add Tailscale to AIO or open an inbound port.
- NMG bootstrap must run from `main` and contain no SSH tunnel or AIO private-key dependency.

---

### Task 1: Add a static contract for remote execution

**Files:**
- Create: `acer-mgmt/compose/tests/test-aio-semaphore-runner.sh`
- Modify: `acer-mgmt/compose/tests/test-tailscale-operator-bootstrap.sh`

**Interfaces:**
- Consumes: Semaphore stack, Vault Agent template, AIO Runner stack, NMG bootstrap script.
- Produces: a repeatable static check that prevents reintroducing SSH tunnelling or plain-text secrets.

- [ ] **Step 1: Write the failing test**

Assert that the Semaphore stack enables remote runners and reads the registration
token from its Vault-rendered env file; assert that the AIO Runner Compose file
uses a persistent token/config mount and no published port; assert that the
bootstrap script sets `vault_addr=https://vault.imcherry5778.xyz` and contains
neither `/run/secrets/acer.pem` nor `ssh -i`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash compose/tests/test-aio-semaphore-runner.sh`

Expected: failure because the Runner stack and remote-runner configuration do
not yet exist.

- [ ] **Step 3: Implement the minimal source changes in Tasks 2 and 3**

Do not weaken the assertions. The test becomes green only after both central
and AIO source contracts exist.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash compose/tests/test-aio-semaphore-runner.sh`

Expected: `AIO_SEMAPHORE_RUNNER_CONTRACT=PASS`.

- [ ] **Step 5: Commit**

Commit the test together with the source it validates after Tasks 2 and 3.

### Task 2: Enable central remote Runner registration through Vault

**Files:**
- Modify: `acer-mgmt/compose/stacks/cicd/semaphore/compose.yaml`
- Modify: `acer-mgmt/compose/stacks/security/vault-agent/config/agent.hcl`
- Create: `acer-mgmt/compose/scripts/bootstrap-vault-semaphore-runner.sh`

**Interfaces:**
- Consumes: `kv/mgmt/cicd/semaphore-runner/aio.runner_registration_token`.
- Produces: `SEMAPHORE_USE_REMOTE_RUNNER=true` and
  `SEMAPHORE_RUNNER_REGISTRATION_TOKEN` in the Semaphore container.

- [ ] **Step 1: Generate and store the registration token only in Vault**

The bootstrap script must create a cryptographically random token when absent,
write it with `vault kv put -mount=kv`, and print only a value-free completion
message. It must support an explicit token environment variable for controlled
recovery without echoing it.

- [ ] **Step 2: Render the token through Vault Agent**

Append `SEMAPHORE_RUNNER_REGISTRATION_TOKEN={{ .Data.data.runner_registration_token }}`
to the existing `cicd/semaphore.env` template. The compose stack already reads
that file; add only `SEMAPHORE_USE_REMOTE_RUNNER: "true"` to Compose.

- [ ] **Step 3: Recreate Semaphore and verify configuration**

Run the Vault bootstrap, wait for Vault Agent rendering, recreate Semaphore,
then verify health and Runner CLI availability without printing the token.

### Task 3: Create the reproducible AIO Runner service

**Files:**
- Create: `acer-aio/40-semaphore-runner/Dockerfile`
- Create: `acer-aio/40-semaphore-runner/compose.yaml`
- Create: `acer-aio/40-semaphore-runner/README.md`
- Create: `acer-aio/40-semaphore-runner/register-runner.sh`

**Interfaces:**
- Consumes: a one-time registration token supplied in a `0600` temporary file;
  `https://semaphore.imcherry5778.xyz` as `web_host`.
- Produces: a persistent `/var/lib/acer-semaphore-runner/config.runner.json`
  containing the issued Runner token, and a `semaphore-aio-runner` service.

- [ ] **Step 1: Build a pinned Runner image**

Base on `semaphoreui/semaphore:v2.18.25`; install `curl`, `jq`, `git`, `tar`,
then install kubectl `v1.35.6` and Helm `v3.19.0` using the checksums/URLs used
by the mgmt Semaphore Dockerfile. Run as the non-root Semaphore UID.

- [ ] **Step 2: Write a Compose service with no inbound publication**

Mount the root-owned state directory at `/var/lib/semaphore-runner` and execute
`semaphore runner start --config /var/lib/semaphore-runner/config.runner.json`.
Use `restart: unless-stopped`, a healthcheck that confirms a Runner process is
present, and no `ports`, host network, Docker socket, or secret mount.

- [ ] **Step 3: Write an idempotent enrollment script**

The script accepts a token-file path, creates the state directory with `0700`,
writes a config with the public Semaphore URL, calls `semaphore runner register
--registration-token-file`, starts Compose, and securely removes the temporary
registration-token file. It must refuse a group/world-readable token file.

- [ ] **Step 4: Document installation and recovery**

Document only value-free commands: initial enrollment, runner status, log
inspection, unregister/re-register, and state backup. State that Runner tokens
are persistent secrets and must not be copied into Git.

### Task 4: Convert NMG bootstrap to direct AIO execution and register it

**Files:**
- Modify: `acer-mgmt/compose/scripts/tailscale/semaphore-bootstrap-operator.sh`
- Modify: `acer-mgmt/compose/scripts/reconcile-tailscale-operator-tasks.sh`

**Interfaces:**
- Consumes: task-scoped NMG AppRole environment and the AIO Runner.
- Produces: an NMG task that reads Vault via the public hostname and calls the
  Kubernetes API endpoint directly from AIO.

- [ ] **Step 1: Remove the SSH-only execution path**

Set `vault_addr=https://vault.imcherry5778.xyz`, remove the `vault_cacert`
argument and all `ssh`, tunnel PID, trap override, and kubeconfig server
rewrite lines. Retain temporary kubeconfig cleanup and Kubernetes CA data.

- [ ] **Step 2: Bind the NMG template to the registered project Runner**

Use Semaphore's Runner API/UI configuration to attach the AIO Runner to project
`acer-aio-nmg`; retain the project-specific serialized template. Verify no
other project template is changed.

- [ ] **Step 3: Reissue the NMG one-time Secret ID and reconcile**

Issue a fresh one-use Secret ID in Vault, update only
`mgmt/tailscale/task-credentials/nmg`, then rerun the NMG reconciler. Never
print the role ID, Secret ID, OAuth credentials, kubeconfig, or task token.

### Task 5: Perform end-to-end verification and commit

**Files:**
- Test: `acer-mgmt/compose/tests/test-aio-semaphore-runner.sh`
- Test: `acer-mgmt/compose/tests/test-tailscale-operator-bootstrap.sh`

- [ ] **Step 1: Verify static contracts**

Run both static tests from an environment with `jq`, and run `bash -n` against
the enrollment and bootstrap scripts.

- [ ] **Step 2: Verify live Runner registration**

Confirm the AIO Runner is online in the NMG Semaphore project, its Runner
config is owner-only, no registration-token file remains, and the container
has no published port.

- [ ] **Step 3: Run the NMG bootstrap template once**

Verify the task is assigned to the AIO Runner, passes Vault authentication,
and reaches the Kubernetes API. Confirm a Tailscale Operator deployment and
NMG ProxyGroup are ready before claiming completion.

- [ ] **Step 4: Commit and synchronize**

Commit source separately in `acer-mgmt` and `acer-aio`, push the reviewed
branches, merge to their respective `main` branches, then update mgmt and AIO
checkouts from origin.
