# Chaos Mesh Central Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single read-only Grafana resilience dashboard in mgmt that correlates each team's Chaos Mesh experiment state with existing ScaleCart and Kubernetes metrics.

**Architecture:** Existing Prometheus Agents in each target cluster discover only their local Chaos Mesh controller pod at port 10080 and remote-write its metrics to mgmt Prometheus. A provisioned Grafana dashboard queries those remote-written metrics; it does not query Kubernetes or create Chaos CRs.

**Tech Stack:** Kubernetes Kustomize, Prometheus v3 Agent mode, PromQL, Grafana file provisioning, Docker Compose, PowerShell, Bash.

## Global Constraints

- Keep Chaos Mesh chart version `2.8.3`, `clusterScoped: false`, target namespace `scalecart`, and Dashboard disabled.
- Keep every existing Chaos experiment paused; do not apply `chaos-mesh-team-experiments`.
- Do not introduce `RemoteCluster`, mgmt-to-team Kubernetes API credentials, or a central Chaos Controller.
- Preserve the existing `cluster` external label emitted by each Prometheus Agent.
- The only new scrape target is the local `chaos-mesh` controller pod matching `app.kubernetes.io/component=controller-manager` on port `10080`.
- Disconnected clusters must surface as no data/unavailable; absence must never be represented as healthy.

---

### Task 1: Add and validate the target-side Chaos Mesh metrics scrape

**Files:**
- Create: `acer-argocd/tests/chaos-mesh-central-observability.ps1`
- Modify: `acer-argocd/monitoring/nmg/node-exporter-agent-config.yaml`
- Modify: `acer-argocd/monitoring/ggg/node-exporter-agent-config.yaml`
- Modify: `acer-argocd/monitoring/khb/node-exporter-agent-config.yaml`
- Modify: `acer-argocd/monitoring/ljw/node-exporter-agent-config.yaml`
- Modify: `acer-argocd/monitoring/oje/node-exporter-agent-config.yaml`

**Interfaces:**
- Consumes: the existing `prometheus-agent-config` ConfigMap in each `monitoring/<team>` overlay.
- Produces: remote-written series with `job="chaos-mesh-controller"`, `cluster=<team>`, and the native Chaos Mesh metric labels.

- [ ] **Step 1: Write the failing validation**

Create `tests/chaos-mesh-central-observability.ps1` with the following assertions.

```powershell
param([string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$teams = @('ggg', 'khb', 'ljw', 'nmg', 'oje')
$required = @(
  "job_name: 'chaos-mesh-controller'",
  "names: ['chaos-mesh']",
  'app_kubernetes_io_component]',
  'regex: controller-manager',
  'replacement: ''${1}:10080''',
  'metrics_path: /metrics'
)

foreach ($team in $teams) {
  $config = Join-Path $RepositoryRoot "monitoring/$team/node-exporter-agent-config.yaml"
  $content = Get-Content -Raw -LiteralPath $config
  foreach ($expected in $required) {
    if (-not $content.Contains($expected)) {
      throw "$team is missing '$expected' from the Chaos Mesh metrics scrape job."
    }
  }
  $rendered = kubectl kustomize (Join-Path $RepositoryRoot "monitoring/$team") | Out-String
  if (-not $rendered.Contains("job_name: 'chaos-mesh-controller'")) {
    throw "$team does not render the Chaos Mesh controller scrape job."
  }
}

Write-Output 'CHAOS_MESH_CENTRAL_OBSERVABILITY_VALIDATION=PASS'
```

- [ ] **Step 2: Run the validation to prove it fails**

Run: `& .\tests\chaos-mesh-central-observability.ps1`

Expected: the first team fails because the `chaos-mesh-controller` job does not exist.

- [ ] **Step 3: Add the same constrained scrape job to every team overlay**

Insert this block immediately after the existing `falco` scrape job and before `scalecart-api` in all five `node-exporter-agent-config.yaml` files.

```yaml
      - job_name: 'chaos-mesh-controller'
        metrics_path: /metrics
        kubernetes_sd_configs:
          - role: pod
            namespaces:
              names: ['chaos-mesh']
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_phase]
            regex: Running
            action: keep
          - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_component]
            regex: controller-manager
            action: keep
          - source_labels: [__meta_kubernetes_pod_ip]
            target_label: __address__
            replacement: '${1}:10080'
          - source_labels: [__meta_kubernetes_pod_name]
            target_label: pod
          - source_labels: [__meta_kubernetes_namespace]
            target_label: namespace
```

The existing Prometheus Agent ClusterRole already has `get`, `list`, and `watch` for pods, so no RBAC expansion is required.

- [ ] **Step 4: Run the validation and rendering checks**

Run:

```powershell
& .\tests\chaos-mesh-central-observability.ps1
foreach ($team in @('ggg','khb','ljw','nmg','oje')) { kubectl kustomize "monitoring/$team" | Out-Null }
git diff --check
```

Expected: `CHAOS_MESH_CENTRAL_OBSERVABILITY_VALIDATION=PASS`, all five Kustomizations render, and `git diff --check` is silent.

- [ ] **Step 5: Commit the GitOps scrape change**

```powershell
git add tests/chaos-mesh-central-observability.ps1 monitoring
git commit -m "feat: collect chaos mesh controller metrics"
```

### Task 2: Provision the mgmt Grafana resilience dashboard

**Files:**
- Create: `acer-mgmt/compose/tests/test-chaos-mesh-observability.sh`
- Create: `acer-mgmt/compose/stacks/observability/grafana/dashboards/Monitoring/chaos_mesh_resilience_overview.json`

**Interfaces:**
- Consumes: mgmt Prometheus datasource UID `prometheus`, external label `cluster`, and series from Task 1.
- Produces: Grafana dashboard UID `chaos-mesh-resilience-overview` in the provisioned `Monitoring` folder.

- [ ] **Step 1: Write the failing dashboard artifact test**

Create `compose/tests/test-chaos-mesh-observability.sh`.

```bash
#!/usr/bin/env bash
set -euo pipefail

dashboard="compose/stacks/observability/grafana/dashboards/Monitoring/chaos_mesh_resilience_overview.json"
test -f "$dashboard"
jq -e '.uid == "chaos-mesh-resilience-overview"' "$dashboard" >/dev/null
jq -e '.title == "Chaos Mesh Resilience Overview"' "$dashboard" >/dev/null
jq -e '.templating.list[] | select(.name == "cluster" and .query.query == "label_values(up{job=\"chaos-mesh-controller\"}, cluster)")' "$dashboard" >/dev/null
jq -e '[.panels[].targets[]?.expr] | join("\n") | contains("chaos_controller_manager_chaos_experiments")' "$dashboard" >/dev/null
jq -e '[.panels[].targets[]?.expr] | join("\n") | contains("chaos_controller_manager_emitted_event_total")' "$dashboard" >/dev/null
jq -e '[.panels[].targets[]?.expr] | join("\n") | contains("scalecart:api_error_ratio:5m")' "$dashboard" >/dev/null
echo 'CHAOS_MESH_GRAFANA_ARTIFACT_VALIDATION=PASS'
```

- [ ] **Step 2: Run the artifact test to prove it fails**

Run: `bash compose/tests/test-chaos-mesh-observability.sh`

Expected: `test -f` fails because the dashboard file is absent.

- [ ] **Step 3: Add the provisioned dashboard**

Create the JSON dashboard with these exact invariants:

```json
{
  "uid": "chaos-mesh-resilience-overview",
  "title": "Chaos Mesh Resilience Overview",
  "tags": ["chaos-mesh", "resilience", "read-only"],
  "templating": {
    "list": [
      {
        "name": "cluster",
        "type": "query",
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "query": { "query": "label_values(up{job=\"chaos-mesh-controller\"}, cluster)" },
        "includeAll": true,
        "allValue": ".*"
      },
      {
        "name": "namespace",
        "type": "query",
        "datasource": { "type": "prometheus", "uid": "prometheus" },
        "query": { "query": "label_values(chaos_controller_manager_chaos_experiments{cluster=~\"$cluster\"}, namespace)" },
        "includeAll": true,
        "allValue": ".*"
      }
    ]
  }
}
```

Add panels with PromQL expressions exactly as follows. Use Stat panels for the first three, a Table panel for the experiment state, and Time series panels for the last two.

```promql
sum by (cluster) (up{job="chaos-mesh-controller",cluster=~"$cluster"})
sum by (cluster) (chaos_controller_manager_chaos_experiments{cluster=~"$cluster",namespace=~"$namespace",phase!="paused"})
sum by (cluster) (chaos_controller_manager_chaos_experiments{cluster=~"$cluster",namespace=~"$namespace",phase="paused"})
sum by (cluster, kind, namespace, phase) (chaos_controller_manager_chaos_experiments{cluster=~"$cluster",namespace=~"$namespace"})
sum by (cluster, reason) (increase(chaos_controller_manager_emitted_event_total{cluster=~"$cluster",type="Warning"}[$__rate_interval]))
scalecart:api_error_ratio:5m{cluster=~"$cluster"}
scalecart:api_latency:p95_5m{cluster=~"$cluster"}
sum by (cluster) (kube_node_status_condition{condition="Ready",status="true",cluster=~"$cluster"})
```

Configure all availability panels with a null/no-data value mapped to `Unavailable`, not `Healthy`. Do not add dashboard links or actions that target Chaos Mesh or Kubernetes APIs.

- [ ] **Step 4: Validate the dashboard artifact**

Run:

```bash
chmod +x compose/tests/test-chaos-mesh-observability.sh
bash compose/tests/test-chaos-mesh-observability.sh
jq empty compose/stacks/observability/grafana/dashboards/Monitoring/chaos_mesh_resilience_overview.json
git diff --check
```

Expected: `CHAOS_MESH_GRAFANA_ARTIFACT_VALIDATION=PASS`, `jq empty` returns zero, and `git diff --check` is silent.

- [ ] **Step 5: Commit the Grafana dashboard**

```bash
git add compose/tests/test-chaos-mesh-observability.sh compose/stacks/observability/grafana/dashboards/Monitoring/chaos_mesh_resilience_overview.json
git commit -m "feat: add chaos mesh resilience dashboard"
```

### Task 3: Merge, deploy, and prove read-only central observation

**Files:**
- Verify: `acer-argocd/argocd/monitoring-{nmg,ggg,khb,ljw,oje}-application.yaml`
- Verify: `acer-mgmt/compose/stacks/observability/grafana/compose.yaml`
- Verify: `acer-mgmt/docs/superpowers/specs/2026-07-11-chaos-mesh-central-observability-design.md`

**Interfaces:**
- Consumes: commits from Tasks 1 and 2.
- Produces: synchronized `main` branches, a running Grafana dashboard, and remote-written Chaos Mesh metrics for reachable clusters.


- [ ] **Step 1: Push both feature branches and merge reviewed changes to `main`**

Push the worktree branches, then merge from each primary checkout because `main` is already checked out there:

```powershell
git -C 'C:\Users\User\Desktop\ktcloud4-acer\acer-argocd\.worktrees\feat-chaos-central-observability' push -u origin feat/chaos-central-observability
git -C 'C:\Users\User\Desktop\ktcloud4-acer\acer-mgmt\.worktrees\feat-chaos-central-observability' push -u origin feat/chaos-central-observability
git -C 'C:\Users\User\Desktop\ktcloud4-acer\acer-argocd' pull --ff-only origin main
git -C 'C:\Users\User\Desktop\ktcloud4-acer\acer-argocd' merge --no-ff feat/chaos-central-observability -m 'merge: add chaos mesh central observability'
git -C 'C:\Users\User\Desktop\ktcloud4-acer\acer-argocd' push origin main
git -C 'C:\Users\User\Desktop\ktcloud4-acer\acer-mgmt' pull --ff-only origin main
git -C 'C:\Users\User\Desktop\ktcloud4-acer\acer-mgmt' merge --no-ff feat/chaos-central-observability -m 'merge: add chaos mesh central observability'
git -C 'C:\Users\User\Desktop\ktcloud4-acer\acer-mgmt' push origin main
```

If `main` advances, preserve the incoming commits and create a normal merge commit rather than resetting or overwriting remote work.

- [ ] **Step 2: Let Argo CD synchronize the target monitoring Applications**

Run from mgmt:

```bash
for app in monitoring-nmg monitoring-ggg monitoring-khb monitoring-ljw monitoring-oje; do
  kubectl -n argocd annotate application "$app" argocd.argoproj.io/refresh=hard --overwrite
done
kubectl -n argocd get application monitoring-nmg monitoring-ggg monitoring-khb monitoring-ljw monitoring-oje
```

Expected: nmg and ggg converge when reachable; disconnected khb/ljw/oje remain visibly `Unknown` and are not forced into a false healthy state.


- [ ] **Step 3: Synchronize the mgmt server and reload the Grafana Compose stack**

Run from `/home/user1/acer-mgmt`:

```bash
git -C /home/user1/acer-mgmt pull --ff-only origin main
docker compose --env-file .env -f compose/stacks/observability/grafana/compose.yaml up -d
docker compose --env-file .env -f compose/stacks/observability/grafana/compose.yaml ps
```

Expected: `grafana` is running and healthy. The existing provisioning provider discovers the JSON file within 30 seconds.

- [ ] **Step 4: Verify Prometheus data and Grafana provisioning**

Run from mgmt:

```bash
curl -fsS --get 'http://localhost:9090/api/v1/query' --data-urlencode 'query=up{job="chaos-mesh-controller",cluster=~"nmg|ggg"}'
curl -fsS --get 'http://localhost:9090/api/v1/query' --data-urlencode 'query=chaos_controller_manager_chaos_experiments{cluster="nmg"}'
docker exec grafana wget -qO- http://localhost:3000/api/search?query=Chaos%20Mesh%20Resilience%20Overview
```

Expected: controller targets and the nmg paused experiment metric are returned; Grafana search returns the dashboard UID. Do not mark khb/ljw/oje healthy if their APIs or agents remain unreachable.


- [ ] **Step 5: Prove no chaos action was performed**

Run against nmg:

```bash
ssh -i C:\Users\User\Downloads\acer.pem ubuntu@172.16.1.10 "export KUBECONFIG=/home/ubuntu/.kube/acer-kubeadm.yaml; kubectl -n scalecart get podchaos -o jsonpath='{range .items[*]}{.metadata.name}{\" | \"}{.metadata.annotations.experiment\\.chaos-mesh\\.org/pause}{\"\\n\"}{end}'; kubectl -n chaos-mesh get pods"
```

Expected: every listed PodChaos remains `true`/paused and the controller/daemon are Ready without a new fault-injection event.
