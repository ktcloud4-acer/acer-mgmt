# NMG Tailscale Operator Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Add one manual NMG Semaphore task that restores the Tailscale API endpoint, rotates the NMG Argo CD credential through Vault and ESO, then reconciles existing NMG GitOps applications.

**Architecture:** The NMG task logs into Vault through an NMG-only AppRole. It uses a temporary direct-recovery kubeconfig to install Tailscale Operator Helm chart 1.98.4, creates the noauth nmg-operator ProxyGroup, writes the renewed Argo connection to Vault, and lets ESO plus Argo CD converge.

**Tech Stack:** Vault KV v2/AppRole, Semaphore v2.18.25, Helm v3.19.0, Tailscale Operator 1.98.4, Kubernetes, Bash, jq, curl.

## Global Constraints

- Only existing Semaphore project acer-aio-nmg is in scope.
- Never store OAuth, kubeconfig, token, or CA values in Git, survey values, normal logs, or shell tracing.
- Use Vault paths mgmt/tailscale/operators/nmg, mgmt/tailscale/bootstrap/nmg, and mgmt/argocd/clusters/nmg exactly.
- Install only in namespace tailscale. Preserve https://nmg-operator.tailc0244b.ts.net.
- Pin Operator chart 1.98.4. ProxyGroup must use noauth transport.
- Temporary credential files must be 0600 and deleted by EXIT trap.

---

### Task 1: Define target and static contract

**Files:**
- Create: compose/config/semaphore/tailscale-operator-projects.json
- Create: compose/scripts/tailscale/semaphore-bootstrap-operator.sh
- Create: compose/tests/test-tailscale-operator-bootstrap.sh

**Interfaces:**
- Input: one fixed NMG record.
- Output: only TAILSCALE_BOOTSTRAP_TEAM=nmg is accepted.

- [ ] **Step 1: Create the target manifest.**

~~~
[
  {
    "team": "nmg",
    "project": "acer-aio-nmg",
    "operator_vault_path": "mgmt/tailscale/operators/nmg",
    "bootstrap_vault_path": "mgmt/tailscale/bootstrap/nmg",
    "argocd_vault_path": "mgmt/argocd/clusters/nmg",
    "proxy_hostname": "nmg-operator"
  }
]
~~~

- [ ] **Step 2: Write a failing Bash contract test.** It must require: manifest length one; team nmg; project acer-aio-nmg; chart variable TAILSCALE_OPERATOR_CHART_VERSION=1.98.4; Helm install; allowImpersonation true; ProxyGroup; hostname nmg-operator; mode noauth; ProxyGroup wait; and trap cleanup EXIT. It must fail if the task contains tskey-, oauth_client_secret, or kubeconfig_b64.

- [ ] **Step 3: Run red.**

Run: bash compose/tests/test-tailscale-operator-bootstrap.sh

Expected: FAIL: missing NMG bootstrap task.

- [ ] **Step 4: Write the minimal task skeleton.**

~~~
#!/usr/bin/env bash
set -euo pipefail
umask 077
[ "$TAILSCALE_BOOTSTRAP_TEAM" = nmg ] || { echo "Only nmg is enabled." >&2; exit 1; }
TAILSCALE_OPERATOR_CHART_VERSION=1.98.4
WORK_DIR=$(mktemp -d)
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT
~~~

- [ ] **Step 5: Re-run red.** Expected: only unimplemented Helm and ProxyGroup assertions fail.

- [ ] **Step 6: Commit.**

~~~
git add compose/config/semaphore/tailscale-operator-projects.json compose/scripts/tailscale/semaphore-bootstrap-operator.sh compose/tests/test-tailscale-operator-bootstrap.sh
git commit -m "test: define NMG Tailscale bootstrap contract"
~~~

### Task 2: Provision NMG-scoped Vault credentials

**Files:**
- Create: compose/scripts/bootstrap-vault-tailscale-operator.sh
- Modify: compose/vault-secrets.env.example
- Modify: compose/tests/test-tailscale-operator-bootstrap.sh

**Interfaces:**
- Input: operator terminal variables NMG_TAILSCALE_OAUTH_CLIENT_ID, NMG_TAILSCALE_OAUTH_CLIENT_SECRET, NMG_BOOTSTRAP_KUBECONFIG_B64.
- Output: NMG OAuth/recovery KV data and AppRole semaphore-tailscale-bootstrap-nmg.

- [ ] **Step 1: Add red tests requiring exactly these policy paths.**

~~~
path "kv/data/mgmt/tailscale/operators/nmg" { capabilities = ["read"] }
path "kv/data/mgmt/tailscale/bootstrap/nmg" { capabilities = ["read"] }
path "kv/data/mgmt/argocd/clusters/nmg" { capabilities = ["read", "update"] }
~~~

The test rejects mgmt/argocd/clusters/*.

- [ ] **Step 2: Run red.** Expected: FAIL: missing Vault bootstrap script.

- [ ] **Step 3: Implement the bootstrap script.** It must require all three terminal-only values; create the shown policy; create an AppRole with 30 minute token TTL and one-use 24 hour SecretID; write OAuth pair, recovery kubeconfig, and role ID/SecretID to the NMG Vault paths; output no values.

- [ ] **Step 4: Add only the three variable names and an “enter only in one-time shell” warning to compose/vault-secrets.env.example.**

- [ ] **Step 5: Verify green.**

Run: bash compose/tests/test-tailscale-operator-bootstrap.sh; bash -n compose/scripts/bootstrap-vault-tailscale-operator.sh

Expected: TAILSCALE_OPERATOR_BOOTSTRAP_CONTRACT=PASS.

- [ ] **Step 6: Commit.**

~~~
git add compose/scripts/bootstrap-vault-tailscale-operator.sh compose/vault-secrets.env.example compose/tests/test-tailscale-operator-bootstrap.sh
git commit -m "feat: add NMG Tailscale Vault bootstrap"
~~~

### Task 3: Reconcile a single manual Semaphore template

**Files:**
- Modify: compose/stacks/cicd/semaphore/Dockerfile
- Create: compose/scripts/reconcile-tailscale-operator-tasks.sh
- Modify: compose/tests/test-tailscale-operator-bootstrap.sh

**Interfaces:**
- Input: the NMG target record and mgmt/tailscale/task-credentials/nmg.
- Output: one environment named NMG Tailscale bootstrap and one manual template named Bootstrap Tailscale Operator and Argo CD.

- [ ] **Step 1: Add red tests requiring ARG HELM_VERSION=v3.19.0, reconciler file, exact template name, and allow_parallel_tasks false.**

- [ ] **Step 2: Run red.** Expected: FAIL: Semaphore image must pin Helm.

- [ ] **Step 3: Add pinned Helm installation.**

~~~
ARG HELM_VERSION=v3.19.0
RUN apk add --no-cache curl tar \
    && curl -fsSL "https://get.helm.sh/helm-$HELM_VERSION-linux-amd64.tar.gz" -o /tmp/helm.tar.gz \
    && tar -xzf /tmp/helm.tar.gz -C /tmp \
    && install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm \
    && helm version --short \
    && rm -rf /tmp/helm.tar.gz /tmp/linux-amd64
~~~

- [ ] **Step 4: Implement reconciler using the existing Semaphore API pattern.** Reject any manifest not containing exactly NMG. Create or update project acer-aio-nmg environment with fixed team nmg, VAULT_ROLE_ID, and VAULT_SECRET_ID; create or update template with playbook compose/scripts/tailscale/semaphore-bootstrap-operator.sh, app bash, survey_vars [], and allow_parallel_tasks false. Never print AppRole fields.

- [ ] **Step 5: Verify green.**

Run: bash compose/tests/test-tailscale-operator-bootstrap.sh; bash -n compose/scripts/reconcile-tailscale-operator-tasks.sh; docker compose -f compose/stacks/cicd/semaphore/compose.yaml config

- [ ] **Step 6: Commit.**

~~~
git add compose/stacks/cicd/semaphore/Dockerfile compose/scripts/reconcile-tailscale-operator-tasks.sh compose/tests/test-tailscale-operator-bootstrap.sh
git commit -m "feat: add NMG Tailscale Semaphore task"
~~~

### Task 4: Implement recovery task

**Files:**
- Modify: compose/scripts/tailscale/semaphore-bootstrap-operator.sh
- Modify: compose/tests/test-tailscale-operator-bootstrap.sh

**Interfaces:**
- Input: fixed NMG AppRole values.
- Output: ready Operator and ProxyGroup, refreshed NMG Argo object, ESO refresh.

- [ ] **Step 1: Add red checks for Helm install, pinned version, ProxyGroup creation/wait, argocd-manager token issuance, Vault NMG write, and ExternalSecret force-sync.**

- [ ] **Step 2: Run red.** Expected: first missing recovery gate.

- [ ] **Step 3: Implement Vault login against https://vault:8200 using the scoped AppRole and CA. Decode recovery kubeconfig from mgmt/tailscale/bootstrap/nmg to a 0600 temporary file. Read OAuth only into variables then unset them after Helm.**

- [ ] **Step 4: Install exact Operator and ProxyGroup.**

~~~
helm upgrade --install tailscale-operator tailscale/tailscale-operator \
  --namespace tailscale --create-namespace --version "$TAILSCALE_OPERATOR_CHART_VERSION" \
  --set-string oauth.clientId="$OAUTH_ID" \
  --set-string oauth.clientSecret="$OAUTH_SECRET" \
  --set-string apiServerProxyConfig.allowImpersonation="true" --wait --timeout 180s
~~~

Apply ProxyGroup nmg-operator with type kube-apiserver, replicas one, tag:k8s-nmg, hostname nmg-operator, mode noauth. Wait 240 seconds for ProxyGroupReady.

- [ ] **Step 5: Create dedicated argocd-manager RBAC, issue a one-hour token, obtain CA data from recovery kubeconfig, and write only name nmg, exact proxy server, and compact bearer-token/CA config to mgmt/argocd/clusters/nmg. Do not write direct FIP to the Argo object.**

- [ ] **Step 6: Force argocd-cluster-nmg ExternalSecret refresh. Wait for cluster-nmg update; require cinder-csi-nmg and scalecart-nmg to leave Unknown; output only app name, sync, health.**

- [ ] **Step 7: Verify green.**

Run: bash compose/tests/test-tailscale-operator-bootstrap.sh

Expected: TAILSCALE_OPERATOR_BOOTSTRAP_CONTRACT=PASS.

- [ ] **Step 8: Commit.**

~~~
git add compose/scripts/tailscale/semaphore-bootstrap-operator.sh compose/tests/test-tailscale-operator-bootstrap.sh
git commit -m "feat: bootstrap NMG Tailscale and Argo connection"
~~~

### Task 5: Document and run controlled NMG pilot

**Files:**
- Create: docs/runbooks/tailscale-operator-bootstrap.md
- Modify: compose/README.md

**Interfaces:**
- Input: committed task plus one-time OAuth and recovery kubeconfig.
- Output: auditable manual recovery.

- [ ] **Step 1: Document tailnet prerequisites:** NMG-only OAuth client with General/Services, Devices/Core, Keys/Auth Keys write; tag:k8s-operator-nmg owns tag:k8s-nmg; mgmt reaches that tag on TCP 443.

- [ ] **Step 2: Document a read -s one-time shell procedure for the three required variables, followed by bash compose/scripts/bootstrap-vault-tailscale-operator.sh and immediate unset.**

- [ ] **Step 3: Rebuild and reconcile.**

Run: docker compose -f compose/stacks/cicd/semaphore/compose.yaml up -d --build && bash compose/scripts/reconcile-tailscale-operator-tasks.sh

Expected: exactly one acer-aio-nmg bootstrap template.

- [ ] **Step 4: Start it manually.** Success requires ready Operator, ready ProxyGroup, refreshed cluster-nmg, three Ready NMG nodes, Cinder CSI Healthy, and no silent Unknown NMG app.

- [ ] **Step 5: Run regressions and commit.**

Run: bash compose/tests/test-tailscale-operator-bootstrap.sh; bash compose/tests/test-argocd-cluster-vault-sync.sh; git diff --check

~~~
git add compose/README.md docs/runbooks/tailscale-operator-bootstrap.md
git commit -m "docs: run NMG Tailscale bootstrap from Semaphore"
~~~

## Plan self-review

- **Spec coverage:** Covers NMG-only scope, Vault-only credentials, scoped AppRole, pinned Operator, tailscale namespace, noauth ProxyGroup, Argo Vault/ESO refresh, cleanup, and health gates.
- **Placeholder scan:** No unfinished placeholder, secret literal, free-text target, or unpinned chart.
- **Interface consistency:** Every task uses NMG, acer-aio-nmg, the same Vault paths, nmg-operator, and chart 1.98.4.
