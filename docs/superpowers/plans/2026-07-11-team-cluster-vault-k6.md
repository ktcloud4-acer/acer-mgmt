# Team Cluster Vault and k6 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (recommended) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Vault the source of truth for all five Argo CD target-cluster credentials and Semaphore secrets, then expose one isolated k6 HPA task in each team Semaphore project.

**Architecture:** The existing working Argo CD cluster Secrets are imported into `kv/mgmt/argocd/clusters/<team>`. A management-cluster External Secrets Operator reads those paths through a Vault Kubernetes-auth role and recreates the labelled Argo CD cluster Secrets. Semaphore Compose consumes the existing Vault Agent-rendered env file rather than root `.env`; a checked-in manifest maps the five existing team projects to the same k6 runner with isolated target settings.

**Tech Stack:** Kubernetes, Argo CD Applications, External Secrets Operator v2.7.0, HashiCorp Vault KV v2/Kubernetes auth, Docker Compose, Semaphore UI API, Bash, Node.js static-contract tests, PowerShell manifest tests.

## Global Constraints

- Target clusters are exactly `ggg`, `khb`, `ljw`, `nmg`, and `oje`.
- Never commit or echo bearer tokens, kubeconfigs, CA data, Vault tokens, database passwords, or API credentials.
- Root `.env` retains only non-secret configuration; Semaphore must read secrets from `/home/mgmt-data/vault-agent/secrets/cicd/semaphore.env`.
- A Semaphore team project has exactly one `ScaleCart API HPA Load Test` task; only non-secret rate/duration inputs are user-overridable.
- Do not add Chaos Mesh `RemoteCluster` resources in this change.

---

### Task 1: Define and test the management ESO/Argo cluster-secret manifests

**Files:**
- Create: `acer-argocd/security/eso/mgmt/{kustomization.yaml,vault-auth.yaml,clustersecretstore.yaml,argocd-cluster-externalsecrets.yaml}`
- Create: `acer-argocd/argocd/{external-secrets-mgmt-application.yaml,eso-config-mgmt-application.yaml}`
- Create: `acer-argocd/tests/team-cluster-vault-sync.ps1`

**Interfaces:**
- Consumes: Vault KV paths `mgmt/argocd/clusters/{ggg,khb,ljw,nmg,oje}` with `name`, `server`, and `config` fields.
- Produces: five `argocd.argoproj.io/secret-type: cluster` Secrets in namespace `argocd` and a `ClusterSecretStore/vault-mgmt`.

- [ ] **Step 1: Write the failing manifest contract test**

```powershell
$clusters = @('ggg', 'khb', 'ljw', 'nmg', 'oje')
foreach ($cluster in $clusters) {
  Assert-FileContains $externalSecret "name: argocd-cluster-$cluster"
  Assert-FileContains $externalSecret "key: mgmt/argocd/clusters/$cluster"
}
Assert-FileContains $store 'mountPath: kubernetes-mgmt'
Assert-FileContains $store 'role: argocd-cluster-reader'
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `pwsh -File tests/team-cluster-vault-sync.ps1`

Expected: failure because the management ESO manifests do not exist.

- [ ] **Step 3: Add the minimal manifests**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: argocd-cluster-ggg
  namespace: argocd
spec:
  secretStoreRef: { name: vault-mgmt, kind: ClusterSecretStore }
  target:
    name: cluster-ggg
    template:
      metadata:
        labels:
          argocd.argoproj.io/secret-type: cluster
  data:
    - secretKey: name
      remoteRef: { key: mgmt/argocd/clusters/ggg, property: name }
```

Repeat the three `name`, `server`, and `config` mappings for all five teams. Deploy the ESO Helm chart to `https://kubernetes.default.svc` before its configuration Application using Argo sync waves.

- [ ] **Step 4: Run the contract and render tests**

Run: `pwsh -File tests/team-cluster-vault-sync.ps1; kubectl kustomize security/eso/mgmt`

Expected: exit 0 and five ExternalSecret resources in the rendered output.

- [ ] **Step 5: Commit**

```bash
git add security/eso/mgmt argocd/external-secrets-mgmt-application.yaml argocd/eso-config-mgmt-application.yaml tests/team-cluster-vault-sync.ps1
git commit -m "feat: sync Argo cluster credentials from Vault"
```

### Task 2: Add non-interactive Vault import and Kubernetes-auth bootstrap scripts

**Files:**
- Create: `acer-mgmt/compose/scripts/import-argocd-cluster-secrets.sh`
- Create: `acer-mgmt/compose/scripts/bootstrap-vault-mgmt-eso.sh`
- Create: `acer-mgmt/compose/tests/test-argocd-cluster-vault-sync.sh`
- Modify: `acer-mgmt/compose/vault-secrets.env.example`
- Modify: `acer-mgmt/compose/README.md`

**Interfaces:**
- Consumes: current labelled Argo CD cluster Secrets from `argocd` namespace and the operator-created `/tmp/.vt` Vault token inside the Vault container.
- Produces: Vault paths `kv/mgmt/argocd/clusters/<team>`, `kubernetes-mgmt` auth configuration, and policy/role `argocd-cluster-reader`.

- [ ] **Step 1: Write the failing shell contract test**

```bash
assert_contains "$import_script" 'argocd.argoproj.io/secret-type=cluster'
assert_contains "$import_script" 'kv/mgmt/argocd/clusters/${cluster}'
assert_contains "$bootstrap_script" 'auth enable -path=kubernetes-mgmt kubernetes'
assert_contains "$bootstrap_script" 'argocd-cluster-reader'
assert_not_contains "$import_script" 'echo "$token"'
```

- [ ] **Step 2: Run it and verify it fails**

Run: `bash compose/tests/test-argocd-cluster-vault-sync.sh`

Expected: failure because neither script exists.

- [ ] **Step 3: Implement safe import/bootstrap scripts**

The import script must iterate the fixed five names, decode `name`, `server`, and
`config` only into shell variables, and execute `docker exec vault vault kv put`
without printing values. The bootstrap script must create a restricted Vault
policy and Kubernetes auth role for `external-secrets/external-secrets`, then
write the API server, CA, and token-reviewer data through stdin/temp files with
`umask 077` and a cleanup trap.

- [ ] **Step 4: Run static tests and shell syntax checks**

Run: `bash compose/tests/test-argocd-cluster-vault-sync.sh; bash -n compose/scripts/import-argocd-cluster-secrets.sh compose/scripts/bootstrap-vault-mgmt-eso.sh`

Expected: both commands exit 0.

- [ ] **Step 5: Commit**

```bash
git add compose/scripts/import-argocd-cluster-secrets.sh compose/scripts/bootstrap-vault-mgmt-eso.sh compose/tests/test-argocd-cluster-vault-sync.sh compose/vault-secrets.env.example compose/README.md
git commit -m "feat: manage Argo cluster credentials in Vault"
```

### Task 3: Convert Semaphore and central Chaos issuer secrets to Vault rendering

**Files:**
- Modify: `acer-mgmt/compose/stacks/cicd/semaphore/compose.yaml`
- Modify: `acer-mgmt/compose/stacks/security/vault-agent/config/agent.hcl`
- Modify: `acer-mgmt/compose/tests/test-semaphore-chaos-dashboard-token.sh`
- Create: `acer-mgmt/compose/tests/test-semaphore-vault-env.sh`

**Interfaces:**
- Consumes: `/home/mgmt-data/vault-agent/secrets/cicd/semaphore.env` and Vault path `kv/mgmt/chaos-dashboard-token-issuer` field `kubeconfig_b64`.
- Produces: semaphore and semaphore-db containers configured without Compose interpolation of a secret from root `.env`; the central token issuer receives `CHAOS_TOKEN_ISSUER_KUBECONFIG_B64` from a Vault-rendered file only.

- [ ] **Step 1: Write failing Semaphore env contract tests**

```bash
assert_contains "$compose_file" 'env_file:'
assert_contains "$compose_file" '/vault-agent/secrets/cicd/semaphore.env'
assert_not_contains "$compose_file" '${SEMAPHORE_DB_PASSWORD'
assert_not_contains "$compose_file" '${ADMIN_PASSWORD'
assert_contains "$vault_agent" 'kv/data/mgmt/chaos-dashboard-token-issuer'
assert_contains "$vault_agent" 'CHAOS_TOKEN_ISSUER_KUBECONFIG_B64='
```

- [ ] **Step 2: Run tests and verify they fail**

Run: `bash compose/tests/test-semaphore-vault-env.sh; bash compose/tests/test-semaphore-chaos-dashboard-token.sh`

Expected: first test fails because Compose currently interpolates root `.env` secrets; second test fails because it forbids the new Vault template.

- [ ] **Step 3: Implement the conversion**

Attach the Vault-rendered env file to both Semaphore services and remove all
secret `environment` entries that currently interpolate root `.env`. Extend the
Vault Agent configuration to render the issuer variable from the new Vault
resource, then update the existing test to require that Vault source.

- [ ] **Step 4: Verify Compose resolution without root secrets**

Run: `bash compose/tests/test-semaphore-vault-env.sh; bash compose/tests/test-semaphore-chaos-dashboard-token.sh; docker compose --env-file compose/vault-secrets.env.example -f compose/stacks/cicd/semaphore/compose.yaml config`

Expected: all commands exit 0 and no root-secret interpolation error occurs.

- [ ] **Step 5: Commit**

```bash
git add compose/stacks/cicd/semaphore/compose.yaml compose/stacks/security/vault-agent/config/agent.hcl compose/tests/test-semaphore-vault-env.sh compose/tests/test-semaphore-chaos-dashboard-token.sh
git commit -m "feat: source Semaphore credentials from Vault"
```

### Task 4: Add team-scoped k6 Semaphore task definitions and reconciliation

**Files:**
- Create: `acer-mgmt/compose/scripts/reconcile-team-k6-tasks.sh`
- Create: `acer-mgmt/compose/config/semaphore/team-k6-projects.json`
- Create: `acer-mgmt/compose/tests/test-team-k6-projects.sh`
- Modify: `acer-mgmt/compose/scripts/k6/run-scalecart-api-hpa.sh`
- Modify: `acer-mgmt/docs/runbooks/scalecart-api-hpa-load-demo-2026-07-11.md`

**Interfaces:**
- Consumes: five pre-existing Semaphore projects and Vault paths `kv/mgmt/k6/<team>`.
- Produces: one idempotent `ScaleCart API HPA Load Test` task per team, each using a unique target base URL and project-scoped Vault credential reference.

- [ ] **Step 1: Write the failing five-team manifest test**

```bash
for team in ggg khb ljw nmg oje; do
  assert_json_project "$manifest" "acer-aio-$team" "https://$team.imcherry5778.xyz"
  assert_json_vault_path "$manifest" "acer-aio-$team" "mgmt/k6/$team"
done
assert_not_contains "$manifest" 'access_token'
```

- [ ] **Step 2: Run it and verify it fails**

Run: `bash compose/tests/test-team-k6-projects.sh`

Expected: failure because the task manifest/reconciler is absent.

- [ ] **Step 3: Add the minimal manifest and API reconciler**

The reconciler must authenticate to Semaphore with the Vault-rendered admin
credential, find projects by exact name, create or update exactly one task
called `ScaleCart API HPA Load Test`, and attach only `K6_BASE_URL`, rate, and
duration as task variables. It must retrieve the bearer credential at task
execution from the project’s Vault path; no access token may enter the manifest
or Semaphore database. Use the checked-in k6 script as the task source and
serialize runs per project.

- [ ] **Step 4: Run tests and dry-run the reconciler**

Run: `bash compose/tests/test-team-k6-projects.sh; bash -n compose/scripts/reconcile-team-k6-tasks.sh; TEAM_K6_DRY_RUN=1 bash compose/scripts/reconcile-team-k6-tasks.sh`

Expected: test/syntax checks pass and dry run lists five project/task bindings without credentials.

- [ ] **Step 5: Commit**

```bash
git add compose/scripts/reconcile-team-k6-tasks.sh compose/config/semaphore/team-k6-projects.json compose/tests/test-team-k6-projects.sh compose/scripts/k6/run-scalecart-api-hpa.sh docs/runbooks/scalecart-api-hpa-load-demo-2026-07-11.md
git commit -m "feat: add team-scoped k6 Semaphore tasks"
```

### Task 5: Runtime migration and end-to-end verification

**Files:**
- Modify: `acer-mgmt/docs/runbooks/scalecart-api-hpa-load-demo-2026-07-11.md`
- Modify: `acer-argocd/docs/argocd-application-inventory-2026-07-10.md`

- [ ] **Step 1: Import and reconcile current cluster credentials**

Run from the management host:

```bash
cd /home/user1/acer-mgmt
compose/scripts/import-argocd-cluster-secrets.sh
compose/scripts/bootstrap-vault-mgmt-eso.sh
```

Expected: five Vault paths exist and output contains names/status only.

- [ ] **Step 2: Apply the management ESO Applications and wait for cluster Secrets**

Run:

```bash
KUBECONFIG=/home/user1/.kube/config kubectl apply -f /home/user1/acer-argocd/argocd/external-secrets-mgmt-application.yaml
KUBECONFIG=/home/user1/.kube/config kubectl apply -f /home/user1/acer-argocd/argocd/eso-config-mgmt-application.yaml
KUBECONFIG=/home/user1/.kube/config kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=cluster
```

Expected: exactly five target clusters are present and their target URLs match the existing Applications.

- [ ] **Step 3: Recreate Semaphore/Vault Agent and reconcile tasks**

Run:

```bash
docker compose --env-file .env -f compose/stacks/security/vault-agent/compose.yaml up -d
docker compose -f compose/stacks/cicd/semaphore/compose.yaml up -d --build
compose/scripts/reconcile-team-k6-tasks.sh
```

Expected: the rendered Vault file is present, Semaphore is healthy, and five exact team tasks exist.

- [ ] **Step 4: Verify control-plane and target health**

Run:

```bash
KUBECONFIG=/home/user1/.kube/config kubectl -n argocd get applications
KUBECONFIG=/home/ubuntu/.kube/acer-kubeadm.yaml kubectl -n scalecart get hpa scalecart-api
```

Expected: existing Applications remain healthy and NMG HPA remains `ScalingActive=True`.

- [ ] **Step 5: Commit docs and final changes**

```bash
git add docs
git commit -m "docs: document Vault-backed team load testing"
```

## Plan Self-Review

- Spec coverage: Tasks 1–2 establish the five Vault-backed Argo connections;
  Task 3 removes Semaphore root secret interpolation and moves the Chaos issuer;
  Task 4 creates the five project-scoped k6 tasks; Task 5 proves runtime state.
- No placeholder scan: all target clusters, secret paths, artifact names, and
  verification commands are explicit.
- Type consistency: all Argo entries use Vault keys `name`, `server`, and
  `config`; all team load resources use project name `acer-aio-<team>` and Vault
  path `mgmt/k6/<team>`.
