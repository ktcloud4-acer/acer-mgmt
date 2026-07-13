# Cluster cert-manager and Deterministic Chaos Mesh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 5개 팀 클러스터에 Vault-backed cert-manager와 Reloader를 설치하고 Chaos Mesh 2.8.3을 결정적으로 렌더링되는 vendor chart로 안전하게 순차 전환한다.

**Architecture:** cert-manager와 Reloader는 모든 팀 클러스터에 먼저 설치하고, 팀별 `ClusterIssuer/vault-internal`은 중앙 Vault의 전용 role을 사용한다. Chaos Mesh 전환은 Argo cluster Secret의 `chaos-pki` 상태를 `legacy → paused → prepare → enabled`로 변경해 기존 Application 이름을 유지한 채 source만 바꾸며, Certificate는 별도 Application이 먼저 발급한다.

**Tech Stack:** Argo CD 3.4.4, ApplicationSet Go template/templatePatch, cert-manager v1.21.0, cmctl v2.5.0, Stakater Reloader chart 2.2.12 (app v1.4.17), Chaos Mesh 2.8.3, Helm, Kustomize, PowerShell tests.

## Global Constraints

- 팀은 정확히 `ggg`, `nmg`, `khb`, `ljw`, `oje`이다.
- cert-manager chart는 `v1.21.0`, Reloader chart는 `2.2.12`, Chaos Mesh chart는 `2.8.3`에 고정한다.
- 수동 갱신 검증용 cmctl은 `v2.5.0` Linux AMD64와 SHA-256 `60e80ba23d18f35032267fb83ab2e6f4b522edce38889ad61292b45a2e9436df`에 고정하며 임시 실행 후 삭제한다.
- Chaos Mesh 2.8.3 package SHA-256은 `c96a2d6490c1fbb0693e18b04e2ab6f60ca45046c64e98ca774f72ac1eaf2a47`이다.
- Vault endpoint는 `https://vault.imcherry5778.xyz`, ClusterIssuer 이름은 `vault-internal`이다.
- cert-manager는 `cert-manager/vault-issuer`의 10분 TokenRequest JWT를 사용하고 정적 Vault token/ServiceAccount token Secret을 사용하지 않는다.
- Leaf는 RSA 2048, `duration: 2160h`, `renewBefore: 720h`, `rotationPolicy: Always`이다.
- Secret 이름은 `chaos-mesh-webhook-certs`, `chaos-mesh-daemon-certs`, `chaos-mesh-daemon-client-certs`, `chaos-mesh-chaosd-client-certs`로 유지한다.
- `randAlphaNum`, `genCA`, `genSignedCert`, Helm 생성 private key, 임의 `rollme` annotation을 vendor chart에서 완전히 제거한다.
- Deployment/DaemonSet `revisionHistoryLimit`은 3이다.
- Reloader는 `reloadStrategy: annotations`, `autoReloadAll: false`, named Secret annotation만 사용한다.
- 공개 Dashboard HTTPS는 기존 Let's Encrypt를 유지하고 Dashboard 10분 JWT 자동화는 수정하지 않는다.
- 기존 Argo Application `chaos-mesh-ggg`, `chaos-mesh-nmg`, `chaos-mesh-khb`, `chaos-mesh-ljw`, `chaos-mesh-oje`를 삭제하거나 새 이름으로 갈아끼우지 않는다.
- `nmg`의 CPU/affinity Pending 문제는 PKI 성공과 분리하며, workload health가 확보되기 전에는 `enabled`로 진행하지 않는다.
- Git 변경의 commit/push/MR/merge/정리 단계는 저장소 `AGENTS.md`의 순차 `y/n` 승인 규칙을 따른다. 아래 commit 단계는 승인 후 실행할 체크포인트이다.

---

## File Structure

All paths in this plan are relative to `C:\Users\User\Desktop\ktcloud4-acer\acer-argocd`.

- Modify `tests/chaos-mesh-team.ps1`, `tests/chaos-mesh-nmg.ps1`: 삭제된 `argocd/` 경로를 현재 `apps/`/ApplicationSet 계약으로 교정.
- Create `tests/vault-pki-platform.ps1`: cert-manager, Reloader, ClusterIssuer, RBAC, Root trust 계약.
- Create `tests/chaos-mesh-deterministic.ps1`: vendor integrity, random function 부재, 이중 렌더 hash 계약.
- Create `tests/chaos-mesh-pki-rollout.ps1`: 4-state label, templatePatch, diff-ignore, Certificate 계약.
- Create `apps/cert-manager.yaml`: 5개 팀 cert-manager ApplicationSet.
- Create `apps/reloader.yaml`: 5개 팀 Reloader ApplicationSet.
- Create `apps/vault-pki.yaml`: 팀별 Vault ClusterIssuer ApplicationSet.
- Create `apps/chaos-mesh-certificates.yaml`: `prepare`/`enabled` 팀에만 Certificate를 생성하는 ApplicationSet.
- Create `security/cert-manager/base/*`: Root trust ConfigMap, TokenRequest RBAC 공통 base.
- Create `security/cert-manager/{ggg,nmg,khb,ljw,oje}/*`: 팀별 exact ClusterIssuer.
- Create `security/chaos-mesh-certificates/base/*`: 4개 Chaos Mesh Certificate.
- Create `vendor/chaos-mesh/*`: verified upstream 2.8.3 chart와 deterministic patch.
- Modify `apps/chaos-mesh-platforms.yaml`: 상태별 source/auto-sync/templatePatch와 제한된 ignore rules.
- Modify `security/eso/mgmt/argocd-cluster-externalsecrets.yaml`: 각 cluster Secret의 `chaos-pki` 상태.
- Modify `clusters/label-team-clusters.sh`: 보조 라벨 스크립트가 선언 상태를 보존.
- Create `chaos-mesh/PKI-ROLLOUT.md`: canary, backup, cutover, renewal, outage, rollback 명령.
- Modify `chaos-mesh/README.md`, `apps/README.md`, `docs/argocd-application-inventory-2026-07-10.md`: 최종 구조 문서화.

## Task 1: Repair the existing Chaos Mesh baseline tests

**Files:**
- Modify: `tests/chaos-mesh-team.ps1`
- Modify: `tests/chaos-mesh-nmg.ps1`

**Interfaces:**
- Consumes: current `apps/chaos-mesh-*.yaml` ApplicationSets.
- Produces: baseline tests that describe current repository reality before PKI work.

- [ ] **Step 1: Reproduce both existing failures**

```powershell
& .\tests\chaos-mesh-team.ps1 -RepositoryRoot (Get-Location).Path
& .\tests\chaos-mesh-nmg.ps1 -RepositoryRoot (Get-Location).Path
```

Expected: both fail on missing paths below `argocd/`.

- [ ] **Step 2: Replace stale paths with current ApplicationSet paths**

```powershell
$platformSet = Join-Path $RepositoryRoot 'apps/chaos-mesh-platforms.yaml'
$namespaceSet = Join-Path $RepositoryRoot 'apps/chaos-mesh-namespaces.yaml'
$rbacSet = Join-Path $RepositoryRoot 'apps/chaos-mesh-rbac.yaml'
$experimentSet = Join-Path $RepositoryRoot 'apps/chaos-mesh-experiments.yaml'
```

For nmg, replace the removed per-team RBAC Application path with `apps/chaos-mesh-rbac.yaml` and assert `path: chaos-mesh/platform/{{.metadata.labels.team}}`. Update old `{{team}}` assertions to `{{.metadata.labels.team}}`; do not relax team, runtime, namespace, paused experiment, or storage assertions.

- [ ] **Step 3: Run both baseline tests**

```powershell
& .\tests\chaos-mesh-team.ps1 -RepositoryRoot (Get-Location).Path
& .\tests\chaos-mesh-nmg.ps1 -RepositoryRoot (Get-Location).Path
```

Expected: `CHAOS_MESH_TEAM_VALIDATION=PASS` and the nmg test exits 0.

- [ ] **Step 4: Commit after explicit approval**

```powershell
git add tests/chaos-mesh-team.ps1 tests/chaos-mesh-nmg.ps1
git commit -m "test(chaos): 현재 ApplicationSet 경로로 계약 교정"
```

## Task 2: Install cert-manager, Reloader, and team Vault issuers

**Files:**
- Create: `tests/vault-pki-platform.ps1`
- Create: `apps/cert-manager.yaml`
- Create: `apps/reloader.yaml`
- Create: `apps/vault-pki.yaml`
- Create: `security/cert-manager/base/kustomization.yaml`
- Create: `security/cert-manager/base/vault-issuer-rbac.yaml`
- Create: `security/cert-manager/base/root-ca.crt`
- Create: `security/cert-manager/{ggg,nmg,khb,ljw,oje}/kustomization.yaml`
- Create: `security/cert-manager/{ggg,nmg,khb,ljw,oje}/clusterissuer.yaml`

**Interfaces:**
- Consumes: merged `acer-mgmt` PKI, public `root-ca.crt`, five Vault auth/PKI roles.
- Produces: healthy cert-manager/Reloader and `ClusterIssuer/vault-internal` in all five clusters.

- [ ] **Step 1: Write the failing platform contract**

The PowerShell test must parse all three ApplicationSets and all five Kustomize renders. It requires exact versions, `crds.enabled: true`, `enableCertificateOwnerRef: false`, `reloadStrategy: annotations`, `autoReloadAll: false`, `serviceaccounts/token` create-only RBAC, and exact per-team Vault fields.

```powershell
$teams = @('ggg','nmg','khb','ljw','oje')
foreach ($team in $teams) {
  $rendered = kubectl kustomize (Join-Path $RepositoryRoot "security/cert-manager/$team") | Out-String
  foreach ($required in @(
    'kind: ClusterIssuer', 'name: vault-internal',
    "path: pki_int/sign/$team-internal",
    "mountPath: /v1/auth/kubernetes-$team",
    "role: cert-manager-$team",
    'name: vault-issuer', 'namespace: cert-manager',
    'resources:', 'serviceaccounts/token', 'verbs:', '- create'
  )) { if (-not $rendered.Contains($required)) { throw "$team missing $required" } }
  if ($rendered -match 'tokenSecretRef|secretRef:') { throw "$team uses a static token" }
}
Write-Output 'VAULT_PKI_PLATFORM_VALIDATION=PASS'
```

- [ ] **Step 2: Verify red**

Run `& .\tests\vault-pki-platform.ps1 -RepositoryRoot (Get-Location).Path`.

Expected: missing `apps/cert-manager.yaml`.

- [ ] **Step 3: Add cert-manager and Reloader ApplicationSets**

`apps/cert-manager.yaml` source and values:

```yaml
source:
  repoURL: https://charts.jetstack.io
  chart: cert-manager
  targetRevision: v1.21.0
  helm:
    releaseName: cert-manager
    values: |
      crds:
        enabled: true
      enableCertificateOwnerRef: false
      prometheus:
        enabled: true
      podAnnotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9402"
destination:
  server: '{{.server}}'
  namespace: cert-manager
```

`apps/reloader.yaml` source and values:

```yaml
source:
  repoURL: https://stakater.github.io/stakater-charts
  chart: reloader
  targetRevision: 2.2.12
  helm:
    releaseName: reloader
    values: |
      reloader:
        reloadStrategy: annotations
        autoReloadAll: false
        reloadOnCreate: true
        syncAfterRestart: true
destination:
  server: '{{.server}}'
  namespace: reloader
```

Both generators select `tier: team`, use `CreateNamespace=true, ServerSideApply=true`, automated prune/selfHeal, and the existing infinite retry policy.

- [ ] **Step 4: Add the TokenRequest RBAC and public Root trust**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-issuer
  namespace: cert-manager
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: vault-issuer-tokenrequest
  namespace: cert-manager
rules:
  - apiGroups: [""]
    resources: ["serviceaccounts/token"]
    resourceNames: ["vault-issuer"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cert-manager-vault-issuer-tokenrequest
  namespace: cert-manager
subjects:
  - kind: ServiceAccount
    name: cert-manager
    namespace: cert-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: vault-issuer-tokenrequest
```

`base/kustomization.yaml` creates a stable `vault-pki-root-ca` ConfigMap from the real public `root-ca.crt` with `disableNameSuffixHash: true`. Record the certificate's computed SHA-256 in `tests/vault-pki-platform.ps1`; do not hard-code a fabricated fingerprint in advance.

- [ ] **Step 5: Add five explicit ClusterIssuers**

Each file uses this complete shape with the exact team values from the table:

| team | path | mountPath | role |
|---|---|---|---|
| ggg | `pki_int/sign/ggg-internal` | `/v1/auth/kubernetes-ggg` | `cert-manager-ggg` |
| nmg | `pki_int/sign/nmg-internal` | `/v1/auth/kubernetes-nmg` | `cert-manager-nmg` |
| khb | `pki_int/sign/khb-internal` | `/v1/auth/kubernetes-khb` | `cert-manager-khb` |
| ljw | `pki_int/sign/ljw-internal` | `/v1/auth/kubernetes-ljw` | `cert-manager-ljw` |
| oje | `pki_int/sign/oje-internal` | `/v1/auth/kubernetes-oje` | `cert-manager-oje` |

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-internal
spec:
  vault:
    server: https://vault.imcherry5778.xyz
    path: pki_int/sign/ggg-internal
    auth:
      kubernetes:
        mountPath: /v1/auth/kubernetes-ggg
        role: cert-manager-ggg
        serviceAccountRef:
          name: vault-issuer
```

The public Vault HTTPS endpoint already uses a publicly trusted Let's Encrypt chain, so `caBundle` is not set on the ClusterIssuer. The internal Root ConfigMap is a trust publication artifact, not the transport trust for Vault's public endpoint.

- [ ] **Step 6: Add the Vault PKI ApplicationSet**

Use Git source `path: security/cert-manager/{{.metadata.labels.team}}`, destination `server: '{{.server}}'`, namespace `cert-manager`, automated prune/selfHeal, and retry. This is merged only after the cert-manager ApplicationSet has been live and Healthy in all target clusters.

- [ ] **Step 7: Run static validation**

```powershell
& .\tests\vault-pki-platform.ps1 -RepositoryRoot (Get-Location).Path
git diff --check
```

Expected: `VAULT_PKI_PLATFORM_VALIDATION=PASS`.

- [ ] **Step 8: Commit and deploy in two approved Git cycles**

First commit `apps/cert-manager.yaml` and `apps/reloader.yaml`:

```powershell
git commit -m "feat(platform): 팀 클러스터 인증서 컨트롤러 추가"
```

After all ten controller applications are Healthy, commit the Root/RBAC/Issuer resources:

```powershell
git commit -m "feat(pki): 팀별 Vault ClusterIssuer 추가"
```

## Task 3: Define Chaos Mesh Certificates and rollout states

**Files:**
- Create: `tests/chaos-mesh-pki-rollout.ps1`
- Create: `apps/chaos-mesh-certificates.yaml`
- Create: `security/chaos-mesh-certificates/base/kustomization.yaml`
- Create: `security/chaos-mesh-certificates/base/certificates.yaml`
- Modify: `security/eso/mgmt/argocd-cluster-externalsecrets.yaml`
- Modify: `clusters/label-team-clusters.sh`

**Interfaces:**
- Consumes: `ClusterIssuer/vault-internal` Ready=True.
- Produces: four 90-day Certificate resources only when a cluster label is `prepare` or `enabled`.

- [ ] **Step 1: Write the failing rollout contract**

The test requires every ExternalSecret template to have `chaos-pki: legacy`, permits only `legacy|paused|prepare|enabled`, and checks the Certificate ApplicationSet selector includes only `prepare` and `enabled`.

```powershell
$certRender = kubectl kustomize (Join-Path $RepositoryRoot 'security/chaos-mesh-certificates/base') | Out-String
foreach ($name in @('chaos-mesh-cert','chaos-daemon-cert','chaos-daemon-client-cert','chaosd-client-cert')) {
  if (-not $certRender.Contains("name: $name")) { throw "missing Certificate $name" }
}
foreach ($required in @('duration: 2160h','renewBefore: 720h','rotationPolicy: Always','kind: ClusterIssuer','name: vault-internal')) {
  if (-not $certRender.Contains($required)) { throw "missing $required" }
}
Write-Output 'CHAOS_MESH_PKI_ROLLOUT_CONTRACT=PASS'
```

- [ ] **Step 2: Verify red**

Run `& .\tests\chaos-mesh-pki-rollout.ps1 -RepositoryRoot (Get-Location).Path`.

Expected: missing Certificate Kustomization.

- [ ] **Step 3: Add four explicit Certificates**

Common private key block:

```yaml
duration: 2160h
renewBefore: 720h
privateKey:
  algorithm: RSA
  size: 2048
  rotationPolicy: Always
issuerRef:
  name: vault-internal
  kind: ClusterIssuer
  group: cert-manager.io
```

Exact identities:

```yaml
# chaos-mesh-cert -> chaos-mesh-webhook-certs
dnsNames:
  - chaos-mesh-controller-manager
  - chaos-mesh-controller-manager.chaos-mesh
  - chaos-mesh-controller-manager.chaos-mesh.svc
usages:
  - server auth

# chaos-daemon-cert -> chaos-mesh-daemon-certs
dnsNames:
  - chaos-daemon.chaos-mesh.org
  - localhost
usages:
  - server auth

# chaos-daemon-client-cert -> chaos-mesh-daemon-client-certs
dnsNames:
  - controller-manager.chaos-mesh.org
  - localhost
usages:
  - client auth

# chaosd-client-cert -> chaos-mesh-chaosd-client-certs
dnsNames:
  - controller-manager.chaos-mesh.org
  - localhost
usages:
  - client auth
```

All Certificates live in `chaos-mesh`; none embeds Secret data.

- [ ] **Step 4: Add the state-selective Certificate ApplicationSet**

```yaml
generators:
  - clusters:
      selector:
        matchExpressions:
          - key: tier
            operator: In
            values: [team]
          - key: chaos-pki
            operator: In
            values: [prepare, enabled]
```

The generated app name is `chaos-mesh-certificates-{{.metadata.labels.team}}`, Git path is `security/chaos-mesh-certificates/base`, and destination is the cluster's `chaos-mesh` namespace.

- [ ] **Step 5: Initialize every cluster label to legacy**

Add `chaos-pki: legacy` beside `tier` and `team` in all five ESO templates. Update the helper script to apply the same exact default and print `-L team -L chaos-pki`. Do not set ggg to `paused` in this task; this commit is mechanics-only and must have zero runtime certificate effect.

- [ ] **Step 6: Run the rollout contract and current Dashboard regression**

```powershell
& .\tests\chaos-mesh-pki-rollout.ps1 -RepositoryRoot (Get-Location).Path
& .\tests\chaos-mesh-cluster-dashboards.ps1 -RepositoryRoot (Get-Location).Path
git diff --check
```

Expected: rollout contract passes; Dashboard routes remain unchanged.

- [ ] **Step 7: Commit after explicit approval**

```powershell
git add apps/chaos-mesh-certificates.yaml security/chaos-mesh-certificates security/eso/mgmt/argocd-cluster-externalsecrets.yaml clusters/label-team-clusters.sh tests/chaos-mesh-pki-rollout.ps1
git commit -m "feat(chaos): Vault 인증서 준비 상태 모델 추가"
```

## Task 4: Vendor and make Chaos Mesh 2.8.3 deterministic

**Files:**
- Create: `tests/chaos-mesh-deterministic.ps1`
- Create: `vendor/chaos-mesh/*` from the verified upstream package.
- Modify: `vendor/chaos-mesh/templates/_certs.tpl`
- Delete: `vendor/chaos-mesh/templates/cert-manager-certs.yaml`
- Modify: `vendor/chaos-mesh/templates/secrets-configuration.yaml`
- Modify: `vendor/chaos-mesh/templates/controller-manager-deployment.yaml`
- Modify: `vendor/chaos-mesh/templates/chaos-daemon-daemonset.yaml`
- Modify: `vendor/chaos-mesh/templates/mutating-admission-webhooks.yaml`
- Modify: `vendor/chaos-mesh/templates/validating-admission-webhooks.yaml`
- Create: `vendor/chaos-mesh/templates/validate-vault-cert-manager.yaml`
- Modify: `vendor/chaos-mesh/values.yaml`
- Create: `vendor/chaos-mesh/values-acer.yaml`
- Create: `vendor/chaos-mesh/UPSTREAM.md`

**Interfaces:**
- Consumes: four cert-manager-owned stable Secrets and Reloader.
- Produces: byte-for-byte stable Helm render and workloads that restart only for named certificate Secrets.

- [ ] **Step 1: Write the failing deterministic test**

The test must:

1. Assert `Chart.yaml` version 2.8.3.
2. Recursively reject `randAlphaNum`, `genCA`, and `genSignedCert`.
3. Reject rendered Secret objects for the four certificate names.
4. Require `revisionHistoryLimit: 3` on controller and daemon.
5. Require named Reloader annotations.
6. Render twice with Helm and compare SHA-256 hashes.

```powershell
$forbidden = rg -n 'randAlphaNum|genCA|genSignedCert' $chart
if ($LASTEXITCODE -eq 0) { throw "nondeterministic Helm functions remain:`n$forbidden" }
$first = docker run --rm -v "${RepositoryRoot}:/work" -w /work alpine/helm:3.19.0 template chaos-mesh ./vendor/chaos-mesh -n chaos-mesh -f ./vendor/chaos-mesh/values-acer.yaml
$second = docker run --rm -v "${RepositoryRoot}:/work" -w /work alpine/helm:3.19.0 template chaos-mesh ./vendor/chaos-mesh -n chaos-mesh -f ./vendor/chaos-mesh/values-acer.yaml
$h1 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($first -join "`n"))))
$h2 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($second -join "`n"))))
if ($h1 -ne $h2) { throw "render hashes differ: $h1 $h2" }
Write-Output "CHAOS_MESH_DETERMINISTIC_RENDER=PASS sha256=$h1"
```

- [ ] **Step 2: Verify red against the absent vendor chart**

Run `& .\tests\chaos-mesh-deterministic.ps1 -RepositoryRoot (Get-Location).Path`.

Expected: missing `vendor/chaos-mesh/Chart.yaml`.

- [ ] **Step 3: Download and verify the exact upstream package**

Download `https://charts.chaos-mesh.org/chaos-mesh-2.8.3.tgz`, compute SHA-256 before extraction, and stop unless it equals the Global Constraint. Extract its `chaos-mesh/` directory to `vendor/chaos-mesh/`. `UPSTREAM.md` records URL, version, SHA-256, extraction date, and every local patch category.

- [ ] **Step 4: Remove all render-time certificate generation**

- Keep only `webhook.apiVersion` in `_certs.tpl`; delete every cert helper.
- Delete `cert-manager-certs.yaml` because Certificates are owned by the separate Git Application.
- Reduce `secrets-configuration.yaml` to an explanatory comment and no rendered resources.
- Remove unconditional `$caCert`, `$crtPEM`, `$keyPEM` evaluation from both webhook templates.
- Always annotate all three webhook configurations with `cert-manager.io/inject-ca-from: "chaos-mesh/chaos-mesh-cert"` and omit desired `caBundle`.
- Add this hard gate:

```gotemplate
{{- if not .Values.webhook.certManager.enabled }}
{{- fail "the Acer vendor chart requires webhook.certManager.enabled=true and external Certificate resources" }}
{{- end }}
```

- [ ] **Step 5: Remove rollme and add exact rollout ownership**

Controller Deployment metadata:

```yaml
metadata:
  annotations:
    secret.reloader.stakater.com/reload: "chaos-mesh-webhook-certs,chaos-mesh-daemon-client-certs,chaos-mesh-chaosd-client-certs"
spec:
  revisionHistoryLimit: 3
```

DaemonSet metadata:

```yaml
metadata:
  annotations:
    secret.reloader.stakater.com/reload: "chaos-mesh-daemon-certs"
spec:
  revisionHistoryLimit: 3
```

Delete both pod-template `rollme` blocks. Keep user-supplied pod annotations but never use them for certificate rotation.

- [ ] **Step 6: Add the fixed Acer values**

`values-acer.yaml` contains the current resource requests/limits, `clusterScoped: false`, namespace filtering to `scalecart`, containerd socket, Dashboard security/PVC, DNS disabled, and:

```yaml
webhook:
  certManager:
    enabled: true
controllerManager:
  replicaCount: 1
  chaosdSecurityMode: true
chaosDaemon:
  mtls:
    enabled: true
```

Dashboard `rootUrl` remains an ApplicationSet Helm parameter because it varies by team.

- [ ] **Step 7: Run render, API, and forbidden-function checks**

```powershell
& .\tests\chaos-mesh-deterministic.ps1 -RepositoryRoot (Get-Location).Path
git diff --check
```

Expected: deterministic sentinel with one SHA-256; no generated certificate Secret manifests.

- [ ] **Step 8: Commit after explicit approval**

```powershell
git add vendor/chaos-mesh tests/chaos-mesh-deterministic.ps1
git commit -m "fix(chaos): 인증서 렌더링과 rollme 비결정성 제거"
```

## Task 5: Add the four-state source switch without activating it

**Files:**
- Modify: `apps/chaos-mesh-platforms.yaml`
- Modify: `tests/chaos-mesh-pki-rollout.ps1`

**Interfaces:**
- Consumes: cluster label `chaos-pki` with one of four exact values.
- Produces: the existing five `chaos-mesh-ggg`, `chaos-mesh-nmg`, `chaos-mesh-khb`, `chaos-mesh-ljw`, `chaos-mesh-oje` Applications using the legacy or vendor source without deletion/adoption.

- [ ] **Step 1: Extend the failing test for templatePatch**

Require `templatePatch`, all four state strings, `chart: null`, `values: null`, vendor path, `RespectIgnoreDifferences=true`, all three exact webhook names, cainjector jq paths, and the exact Reloader annotation jq path. Reject a selector change that would remove team Applications.

- [ ] **Step 2: Add the exact state machine**

Keep the current external Helm source as the base for `legacy`. Add:

```yaml
templatePatch: |
  {{- $state := index .metadata.labels "chaos-pki" }}
  {{- if or (eq $state "paused") (eq $state "prepare") }}
  spec:
    syncPolicy:
      automated: null
  {{- else if eq $state "enabled" }}
  spec:
    source:
      repoURL: https://gitlab.imcherry5778.xyz/acer-group/acer-argocd.git
      targetRevision: main
      chart: null
      path: vendor/chaos-mesh
      helm:
        releaseName: chaos-mesh
        values: null
        valueFiles: [values-acer.yaml]
        parameters:
          - name: dashboard.rootUrl
            value: https://{{.metadata.labels.team}}-chaos.imcherry5778.xyz
    syncPolicy:
      automated: {prune: true, selfHeal: true}
      syncOptions: [CreateNamespace=true, ServerSideApply=true, RespectIgnoreDifferences=true]
    ignoreDifferences:
      - group: admissionregistration.k8s.io
        kind: MutatingWebhookConfiguration
        name: chaos-mesh-mutation
        jqPathExpressions: ['.webhooks[]?.clientConfig.caBundle']
      - group: admissionregistration.k8s.io
        kind: ValidatingWebhookConfiguration
        name: chaos-mesh-validation
        jqPathExpressions: ['.webhooks[]?.clientConfig.caBundle']
      - group: admissionregistration.k8s.io
        kind: ValidatingWebhookConfiguration
        name: chaos-mesh-validation-auth
        jqPathExpressions: ['.webhooks[]?.clientConfig.caBundle']
      - group: apps
        kind: Deployment
        name: chaos-mesh-controller-manager
        jqPathExpressions: ['.spec.template.metadata.annotations."reloader.stakater.com/last-reloaded-from"']
      - group: apps
        kind: DaemonSet
        name: chaos-daemon
        jqPathExpressions: ['.spec.template.metadata.annotations."reloader.stakater.com/last-reloaded-from"']
  {{- end }}
```

The base generator remains `matchLabels: {tier: team}` so all five existing Applications always remain present. `paused` and `prepare` change source in the generated spec to legacy but disable automated sync; because no sync runs, the live vendor release also stays untouched during rollback preparation.

- [ ] **Step 3: Validate every current label is still legacy**

```powershell
& .\tests\chaos-mesh-pki-rollout.ps1 -RepositoryRoot (Get-Location).Path
& .\tests\chaos-mesh-team.ps1 -RepositoryRoot (Get-Location).Path
git diff --check
```

Expected: both pass and no cluster switches source.

- [ ] **Step 4: Commit after explicit approval**

```powershell
git add apps/chaos-mesh-platforms.yaml tests/chaos-mesh-pki-rollout.ps1
git commit -m "feat(chaos): 상태 기반 PKI source 전환 추가"
```

## Task 6: ggg canary cutover

**Files:**
- Modify in three separately reviewed commits: `security/eso/mgmt/argocd-cluster-externalsecrets.yaml`
- Create before the first state change: `chaos-mesh/PKI-ROLLOUT.md`

**Interfaces:**
- Consumes: healthy ggg cert-manager, Reloader, ClusterIssuer, merged deterministic chart.
- Produces: ggg Chaos Mesh running only Vault-issued Secrets with stable Argo sync.

- [ ] **Step 1: Record and verify the legacy state**

From ggg, record Pod UIDs, Deployment ReplicaSets, DaemonSet ControllerRevisions, Secret serials/fingerprints, webhook caBundle fingerprint, and Dashboard JWT login result. Store secret backups only on the secured ggg host:

```bash
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup="/home/ubuntu/chaos-mesh-pki-backup-$stamp.yaml"
umask 077
kubectl -n chaos-mesh get secret \
  chaos-mesh-webhook-certs chaos-mesh-daemon-certs \
  chaos-mesh-daemon-client-certs chaos-mesh-chaosd-client-certs \
  -o yaml >"$backup"
chmod 600 "$backup"
```

- [ ] **Step 2: Change ggg from legacy to paused and merge only that label change**

Expected live evidence:

```bash
kubectl -n argocd get application chaos-mesh-ggg -o jsonpath='{.spec.syncPolicy.automated}'
```

The output is empty. The Application still exists and no workload revision changes.

- [ ] **Step 3: Remove only Argo tracking from the four legacy Secrets**

```bash
kubectl -n chaos-mesh annotate secret \
  chaos-mesh-webhook-certs chaos-mesh-daemon-certs \
  chaos-mesh-daemon-client-certs chaos-mesh-chaosd-client-certs \
  argocd.argoproj.io/tracking-id-
```

Verify all four still exist, their data hashes are unchanged, and the `chaos-mesh-ggg:/Secret:` tracking values are absent. Do not remove other labels or Secret data.

- [ ] **Step 4: Change ggg from paused to prepare in a second approved Git cycle**

Wait for `chaos-mesh-certificates-ggg` to be Synced/Healthy and all four Certificates to be Ready:

```bash
kubectl -n chaos-mesh wait certificate/chaos-mesh-cert certificate/chaos-daemon-cert \
  certificate/chaos-daemon-client-cert certificate/chaosd-client-cert \
  --for=condition=Ready --timeout=5m
```

Verify every Secret chain ends at the Git Root fingerprint, leaf duration is at most 90 days, keys are 2048-bit RSA, and webhook/daemon/client EKUs match the contract. The legacy Chaos Application remains auto-sync disabled.

- [ ] **Step 5: Change ggg from prepare to enabled in a third approved Git cycle**

Wait for source path `vendor/chaos-mesh`, Synced/Healthy, Deployment rollout, DaemonSet rollout, cainjector-populated caBundle, mTLS, and Dashboard login. Confirm Secret resources have no Argo tracking ID and do have cert-manager metadata.

- [ ] **Step 6: Prove stable rendering and bounded history**

Refresh and sync the same Git revision twice with at least two controller reconciliation intervals. Assert:

- Application stays Synced/Healthy.
- no new ReplicaSet or ControllerRevision appears on a no-op refresh.
- controller and daemon `revisionHistoryLimit` are 3.
- `rollme` is absent.

- [ ] **Step 7: Force one controlled renewal**

Use cmctl's supported manual-renewal API rather than deleting a managed Secret. Download the pinned binary to ggg's temporary directory, verify it, and renew only the daemon server Certificate:

```bash
curl -fsSLo /tmp/cmctl https://github.com/cert-manager/cmctl/releases/download/v2.5.0/cmctl_linux_amd64
printf '%s  %s\n' '60e80ba23d18f35032267fb83ab2e6f4b522edce38889ad61292b45a2e9436df' /tmp/cmctl | sha256sum -c -
chmod 700 /tmp/cmctl
trap 'rm -f /tmp/cmctl' EXIT
before="$(kubectl -n chaos-mesh get controllerrevision -o json | jq '[.items[] | select(.metadata.ownerReferences[]? | .kind == "DaemonSet" and .name == "chaos-daemon")] | length')"
old_cert_revision="$(kubectl -n chaos-mesh get certificate chaos-daemon-cert -o jsonpath='{.status.revision}')"
old_daemon_generation="$(kubectl -n chaos-mesh get daemonset chaos-daemon -o jsonpath='{.metadata.generation}')"
old_controller_generation="$(kubectl -n chaos-mesh get deployment chaos-mesh-controller-manager -o jsonpath='{.metadata.generation}')"
/tmp/cmctl renew --namespace chaos-mesh chaos-daemon-cert
for attempt in $(seq 1 60); do
  new_cert_revision="$(kubectl -n chaos-mesh get certificate chaos-daemon-cert -o jsonpath='{.status.revision}')"
  new_daemon_generation="$(kubectl -n chaos-mesh get daemonset chaos-daemon -o jsonpath='{.metadata.generation}')"
  if [ "$new_cert_revision" -gt "$old_cert_revision" ] && [ "$new_daemon_generation" -gt "$old_daemon_generation" ]; then break; fi
  sleep 5
done
test "$new_cert_revision" -gt "$old_cert_revision"
test "$new_daemon_generation" -gt "$old_daemon_generation"
kubectl -n chaos-mesh wait certificate/chaos-daemon-cert --for=condition=Ready --timeout=5m
kubectl -n chaos-mesh rollout status daemonset/chaos-daemon --timeout=5m
after="$(kubectl -n chaos-mesh get controllerrevision -o json | jq '[.items[] | select(.metadata.ownerReferences[]? | .kind == "DaemonSet" and .name == "chaos-daemon")] | length')"
test "$after" -le 3
test "$after" -le "$((before + 1))"
test "$(kubectl -n chaos-mesh get deployment chaos-mesh-controller-manager -o jsonpath='{.metadata.generation}')" -eq "$old_controller_generation"
```

Verify the daemon certificate serial changes, only the DaemonSet rolls, controller Deployment does not roll, and Argo remains Synced.

- [ ] **Step 8: Exercise the Vault outage window with a disposable Certificate**

From the Windows operator workstation, pause Vault first, create an exact disposable Certificate, prove issuance times out while existing Chaos Mesh Pods stay Ready, and always unpause through `finally`:

```powershell
$key = 'C:\Users\User\Downloads\acer.pem'
$probe = @'
apiVersion: v1
kind: Namespace
metadata:
  name: pki-outage-probe
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: vault-outage-probe
  namespace: pki-outage-probe
spec:
  secretName: vault-outage-probe
  duration: 1h
  renewBefore: 30m
  privateKey:
    algorithm: RSA
    size: 2048
    rotationPolicy: Always
  dnsNames:
    - controller-manager.chaos-mesh.org
  usages:
    - client auth
  issuerRef:
    name: vault-internal
    kind: ClusterIssuer
    group: cert-manager.io
'@

ssh -i $key user1@acer-mgmt 'docker pause vault'
if ($LASTEXITCODE -ne 0) { throw 'Vault pause failed' }
try {
  $probe | ssh -i $key ubuntu@ggg-aio 'kubectl apply -f -'
  if ($LASTEXITCODE -ne 0) { throw 'probe apply failed' }
  ssh -i $key ubuntu@ggg-aio 'if kubectl -n pki-outage-probe wait certificate/vault-outage-probe --for=condition=Ready --timeout=45s; then exit 42; else exit 0; fi'
  if ($LASTEXITCODE -ne 0) { throw 'probe unexpectedly issued while Vault was paused' }
  ssh -i $key ubuntu@ggg-aio 'kubectl -n chaos-mesh wait pod --all --for=condition=Ready --timeout=30s'
  if ($LASTEXITCODE -ne 0) { throw 'existing Chaos Mesh Pods became unhealthy' }
}
finally {
  ssh -i $key user1@acer-mgmt 'docker unpause vault'
}
ssh -i $key ubuntu@ggg-aio 'kubectl -n pki-outage-probe wait certificate/vault-outage-probe --for=condition=Ready --timeout=5m'
if ($LASTEXITCODE -ne 0) { throw 'probe did not recover after Vault unpause' }
ssh -i $key ubuntu@ggg-aio 'kubectl delete namespace pki-outage-probe --wait=true'
```

The expected Vault pause is under one minute. Never delete a production Secret during this probe.

- [ ] **Step 9: Commit the completed runbook after evidence is known**

```powershell
git add chaos-mesh/PKI-ROLLOUT.md
git commit -m "docs(chaos): ggg PKI canary와 rollback 증거 기록"
```

## Task 7: Roll out nmg, khb, ljw, and oje sequentially

**Files:**
- Modify in separate approved state commits: `security/eso/mgmt/argocd-cluster-externalsecrets.yaml`
- Modify: `chaos-mesh/PKI-ROLLOUT.md`

**Interfaces:**
- Consumes: successful ggg canary evidence.
- Produces: all team states `enabled`, or a documented hold with no partial automatic sync.

- [ ] **Step 1: Cut over nmg with explicit gates**

Change only nmg to `paused`, merge, and verify `chaos-mesh-nmg` still exists with automated sync absent. On `nmg-aio`, save the four Secrets to a UTC timestamp-named `chaos-mesh-pki-backup-nmg` file under `/home/ubuntu/` with mode 600, record hashes, and remove only their Argo tracking annotations. Change only nmg to `prepare`, merge, and require `chaos-mesh-certificates-nmg` Healthy plus four Ready Certificates with the approved Root fingerprint. Resolve the known CPU/node-affinity Pending condition before changing only nmg to `enabled`; then require `chaos-mesh-nmg` Healthy, all daemon Pods Ready, mTLS/webhooks functional, Dashboard JWT login successful, no-op sync revision count unchanged, and one daemon-only renewal bounded to three ControllerRevisions.

- [ ] **Step 2: Cut over khb with explicit gates**

Change only khb through three reviewed commits: `legacy → paused`, `paused → prepare`, and `prepare → enabled`. Between the first two commits, store the four legacy Secrets on `khb-aio` in a UTC timestamp-named `chaos-mesh-pki-backup-khb` file under `/home/ubuntu/` with mode 600, verify hashes, and strip only Argo tracking. Before the enabled commit, require `chaos-mesh-certificates-khb` Healthy and four Ready Certificates. After it, require `chaos-mesh-khb` Healthy, approved Root chains, cainjector-owned webhook bundles, working mTLS and Dashboard JWT, unchanged no-op revision counts, and a daemon-only renewal with at most three ControllerRevisions.

- [ ] **Step 3: Cut over ljw with explicit gates**

Change only ljw through `legacy → paused → prepare → enabled`, one reviewed state commit at a time. Save the four Secrets on `ljw-aio` in a UTC timestamp-named `chaos-mesh-pki-backup-ljw` file under `/home/ubuntu/` with mode 600 before removing only Argo tracking. Require `chaos-mesh-certificates-ljw` and four Certificates Ready before enabled. Then require `chaos-mesh-ljw` Healthy, approved Root chains, working webhook/mTLS/Dashboard JWT, stable no-op revision counts, and bounded daemon-only renewal. Stop without changing oje on any failure.

- [ ] **Step 4: Cut over oje with explicit gates**

Change only oje through `legacy → paused → prepare → enabled`, one reviewed state commit at a time. Save the four Secrets on `oje-aio` in a UTC timestamp-named `chaos-mesh-pki-backup-oje` file under `/home/ubuntu/` with mode 600 before stripping only Argo tracking. Require `chaos-mesh-certificates-oje` and all Certificates Ready before enabled. Then require `chaos-mesh-oje` Healthy, approved Root chains, working webhook/mTLS/Dashboard JWT, stable no-op revision counts, and bounded daemon-only renewal. Only after those checks may all five labels be recorded as `enabled`.

- [ ] **Step 5: Verify the fleet**

```bash
kubectl -n argocd get applications -l app.kubernetes.io/part-of=platform-resilience
```

For every team, verify source path `vendor/chaos-mesh`, four Ready Certificates, Vault Root chain, Reloader named annotations, Synced/Healthy, and no no-op revision growth.

## Task 8: Rollback drill and final documentation

**Files:**
- Modify: `chaos-mesh/PKI-ROLLOUT.md`
- Modify: `chaos-mesh/README.md`
- Modify: `apps/README.md`
- Modify: `docs/argocd-application-inventory-2026-07-10.md`

**Interfaces:**
- Consumes: one enabled canary and its secured legacy Secret backup.
- Produces: proven rollback and current inventory.

- [ ] **Step 1: Document the exact rollback state path**

Rollback is `enabled → paused`, not directly to `legacy`. In `paused`, automated sync is disabled and the Certificate Application disappears. Verify Secrets persist because cert-manager owner references are disabled, restore the four legacy Secrets, manually sync the legacy external chart, verify old mTLS/webhook/Dashboard JWT, then change `paused → legacy`.

- [ ] **Step 2: Drill rollback on ggg only if the maintenance window permits**

Record restore duration and all health checks, then repeat the forward `paused → prepare → enabled` sequence. If a live drill is deferred, mark the implementation incomplete; a written procedure alone does not satisfy the design acceptance criteria.

- [ ] **Step 3: Update inventory and responsibility boundaries**

Document cert-manager/Reloader/Vault PKI Applications, vendor chart source, four rollout states, Root trust fingerprint, public Let's Encrypt boundary, and Dashboard JWT separation.

- [ ] **Step 4: Run the complete static suite**

```powershell
& .\tests\chaos-mesh-team.ps1 -RepositoryRoot (Get-Location).Path
& .\tests\chaos-mesh-nmg.ps1 -RepositoryRoot (Get-Location).Path
& .\tests\vault-pki-platform.ps1 -RepositoryRoot (Get-Location).Path
& .\tests\chaos-mesh-pki-rollout.ps1 -RepositoryRoot (Get-Location).Path
& .\tests\chaos-mesh-deterministic.ps1 -RepositoryRoot (Get-Location).Path
& .\tests\chaos-mesh-cluster-dashboards.ps1 -RepositoryRoot (Get-Location).Path
git diff --check
```

Expected: all tests pass, the two render hashes match, and no forbidden random function or private material is found.

- [ ] **Step 5: Commit after explicit approval**

```powershell
git add chaos-mesh/PKI-ROLLOUT.md chaos-mesh/README.md apps/README.md docs/argocd-application-inventory-2026-07-10.md
git commit -m "docs(pki): 멀티클러스터 인증서 운영 절차 확정"
```

## Rollback Decision Table

| Current state | Certificate App | Chaos source in desired spec | Automated sync | Safe next action |
|---|---:|---|---:|---|
| `legacy` | absent | upstream Helm | enabled | enter `paused` |
| `paused` | absent | upstream Helm | disabled | backup/restore/remove tracking |
| `prepare` | present | upstream Helm | disabled | wait Certificates, then enable |
| `enabled` | present | vendor Git chart | enabled | normal operation or return to paused |

## References

- cert-manager Helm installation v1.21.0: https://cert-manager.io/docs/installation/helm/
- cert-manager Vault issuer and TokenRequest RBAC: https://cert-manager.io/docs/configuration/vault/
- Reloader v1.4 Argo CD integration: https://docs.stakater.com/reloader/main/how-to-guides/use-reloader-with-argocd.html
- Argo CD ApplicationSet templatePatch: https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Template/
- Chaos Mesh 2.8.3 chart: https://artifacthub.io/packages/helm/chaos-mesh/chaos-mesh/2.8.3
- Chaos Mesh 2.8.3 source templates: https://github.com/chaos-mesh/chaos-mesh/tree/v2.8.3/helm/chaos-mesh
