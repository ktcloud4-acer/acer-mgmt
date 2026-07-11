# Chaos Mesh Central Observability Design

## Goal

Provide one read-only resilience view in the existing mgmt Grafana for nmg, ggg, khb, ljw, and oje. The view must correlate Chaos Mesh experiment state with ScaleCart service health and cluster health without giving mgmt the ability to create, update, or delete Chaos experiments.

## Context

- Each team cluster already runs a Prometheus Agent that remote-writes to the mgmt Prometheus at `100.117.59.96:9090`.
- The deployed Chaos Mesh controller exposes Prometheus metrics at port `10080`, including `chaos_controller_manager_chaos_experiments` and `chaos_controller_manager_emitted_event_total`.
- mgmt already has Grafana, Prometheus, Traefik, Keycloak, and OAuth2 Proxy. Grafana uses the existing Keycloak role mapping.
- Chaos Mesh runs independently in target clusters. Its Dashboard remains disabled, and experiment CRs remain GitOps-managed and paused by default.

## Chosen Architecture

```text
Target cluster (nmg / ggg / khb / ljw / oje)
  Chaos Mesh Controller :10080 ─┐
  ScaleCart / kube-state metrics ├─ Prometheus Agent ─remote_write─> mgmt Prometheus
  node / kubelet metrics ────────┘                                      │
                                                                     Grafana
                                                                     read-only
```

The per-cluster Prometheus Agent discovers the `chaos-mesh` controller pod and scrapes its `/metrics` endpoint. It labels every sample with the existing team/cluster label before remote-writing it to mgmt. No mgmt-to-team Kubernetes API credential, `RemoteCluster`, central Chaos Controller, or Chaos Dashboard is introduced.

## Components

### Target-cluster GitOps (`acer-argocd`)

Add one scrape job to each existing `monitoring/<team>/node-exporter-agent-config.yaml`.

- Discover only pods in namespace `chaos-mesh` with `app.kubernetes.io/component=controller-manager`.
- Scrape port `10080` on `/metrics`.
- Preserve the existing `cluster` label convention and do not discover Dashboard, Daemon, or arbitrary application pods.
- A cluster that has no reachable Chaos Mesh controller reports an `up=0` target after its Prometheus Agent reconnects; it does not gain write or experiment privileges.

### mgmt observability (`acer-mgmt`)

Add a provisioned Grafana dashboard named **Chaos Mesh Resilience Overview** under the existing `Monitoring` folder.

The dashboard contains:

1. A fixed five-cluster selector (`ggg`, `khb`, `ljw`, `nmg`, `oje`) and an experiment namespace variable.
2. Controller scrape availability (`up`), with a zero-valued fallback for each configured cluster that has no telemetry so it is shown as Unavailable.
3. Current experiments grouped by cluster, kind, experiment namespace, and phase from `chaos_controller_manager_chaos_experiments`. Prometheus reserves `namespace` for the scrape target, so the dashboard uses the metric's `exported_namespace` label for the experiment target namespace.
4. Chaos warning-event rate from `chaos_controller_manager_emitted_event_total`.
5. ScaleCart API request rate, error rate, and latency using the existing remote-written application metrics when available.
6. Node readiness and CPU/memory context from the existing Kubernetes metrics.
7. Explicit no-data states for disconnected clusters; no panel treats absence of metrics as healthy.

Grafana remains the only public UI, behind its existing Traefik HTTPS and Keycloak/OAuth authorization. The dashboard does not call the Kubernetes API and has no action button that can execute a Chaos experiment.

## Safety and Security

- Chaos experiment CR ownership remains in `acer-argocd`; the central dashboard is read-only.
- Existing paused canaries remain paused. No experiment ApplicationSet is applied as part of this work.
- The target-side scrape runs with the existing Prometheus Agent service account and reads only its local metrics endpoint.
- No Argo CD cluster secret, admin kubeconfig, or remote-cluster credential is copied into the mgmt Compose stack.
- Grafana access is governed by the current Keycloak mapping: `platform-admin` Admin, `platform-editor` Editor, and all others Viewer. Editors can modify Grafana dashboards but cannot execute Chaos Mesh operations.

## Rollout and Verification

1. Render and validate all five target Prometheus Agent configurations.
2. Deploy the GitOps change first to nmg and ggg, the currently reachable clusters.
3. Confirm the controller `up` series and experiment metrics appear in mgmt Prometheus with the correct cluster label.
4. Provision the Grafana dashboard and verify nmg/ggg panels. Disconnected khb/ljw/oje must visibly show no data or unavailable, not healthy.
5. Verify a paused PodChaos is displayed as `phase="paused"` and that no workload is restarted or fault injected.
6. Push both repositories, merge reviewed branches to `main`, and let remote targets synchronize through existing GitOps retry behavior.

## Non-goals

- Central execution through `RemoteCluster`.
- Enabling Chaos Dashboard in target clusters.
- Adding Dashboard resource consumption to every team cluster.
- Automatically unpausing or scheduling Chaos experiments.
- Deploying k6 or Scouter; their existing or future metrics can be correlated by Grafana separately.
