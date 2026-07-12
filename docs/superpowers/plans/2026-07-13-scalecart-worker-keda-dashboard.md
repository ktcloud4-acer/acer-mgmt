# ScaleCart Worker KEDA Demo Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a provisioned Grafana dashboard that demonstrates Kafka-driven Worker KEDA scale-out and explains Worker placement capacity.

**Architecture:** A new Monitoring-folder dashboard JSON queries only central Prometheus metrics already available from cluster agents. It separates actual worker-node utilisation from Kubernetes request reservation, and labels the KEDA scale-out signal as derived because central Prometheus lacks a raw ScaledObject Active metric.

**Tech Stack:** Grafana provisioned dashboard JSON, PromQL, Prometheus, kube-state-metrics, node-exporter, shell contract test.

## Global Constraints

- Create `ScaleCart Worker KEDA Demo`; do not modify `ScaleCart API HPA Load Demo` or `ScaleCart SRE Landing`.
- Every workload and Kubernetes query uses `cluster=~"$cluster"` and `namespace="scalecart"` where applicable.
- Use percent ratios in the `0..1` range for Grafana `percentunit` fields.
- Call the derived boolean `KEDA Scale-out Requested`, never `KEDA Active`.
- Use Worker request constants of `0.25` CPU cores and `536870912` bytes.
- Filter worker-node panels to `worker[0-9]+`; the control-plane node is NoSchedule-tainted.

---

### Task 1: Add the dashboard contract test

**Files:**
- Create: `compose/tests/test-scalecart-worker-keda-dashboard.sh`
- Test: `compose/tests/test-scalecart-worker-keda-dashboard.sh`

**Interfaces:**
- Consumes: dashboard file at `compose/stacks/observability/grafana/dashboards/Monitoring/scalecart_worker_keda_demo.json`.
- Produces: `SCALECART_WORKER_KEDA_DASHBOARD=PASS` only when the dashboard contract is complete.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dashboard="$root/compose/stacks/observability/grafana/dashboards/Monitoring/scalecart_worker_keda_demo.json"

test -f "$dashboard" || { echo "missing KEDA dashboard" >&2; exit 1; }
jq empty "$dashboard"
jq -e '.uid == "scalecart-worker-keda-demo"' "$dashboard" >/dev/null
jq -e '.title == "ScaleCart Worker KEDA Demo"' "$dashboard" >/dev/null
jq -e '.templating.list[] | select(.name == "cluster")' "$dashboard" >/dev/null

for title in \
  "Kafka Lag" "Worker Ready / Desired" "KEDA Scale-out Requested" \
  "Pending Worker Pods" "Kafka Lag and Threshold" \
  "Order Produce / Consume Rate" "Worker Replica Timeline" \
  "Worker Node Actual CPU" "Worker Node CPU Request Reservation" \
  "Worker Node Actual Memory" "Worker Node Memory Request Reservation" \
  "Additional Worker Slots by CPU" "Additional Worker Slots by Memory" \
  "Node Placement Status"; do
  jq -e --arg title "$title" '.panels[] | select(.title == $title)' "$dashboard" >/dev/null
done

dashboard_json="$(cat "$dashboard")"
for metric in \
  'scalecart:worker_kafka_lag:max' \
  'scalecart_orders_produced_total' \
  'scalecart_orders_consumed_total' \
  'kube_horizontalpodautoscaler_status_desired_replicas' \
  'kube_pod_status_phase' \
  'node_cpu_seconds_total' \
  'kube_pod_container_resource_requests' \
  'kube_node_status_allocatable' \
  'kube_node_spec_taint'; do
  grep -Fq -- "$metric" <<<"$dashboard_json" || { echo "missing $metric" >&2; exit 1; }
done

grep -Fq -- 'KEDA Scale-out Requested' <<<"$dashboard_json"
grep -Fq -- '536870912' <<<"$dashboard_json"
grep -Fq -- '0.25' <<<"$dashboard_json"
grep -Fq -- 'keda-hpa-scalecart-worker' <<<"$dashboard_json"

echo 'SCALECART_WORKER_KEDA_DASHBOARD=PASS'
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash compose/tests/test-scalecart-worker-keda-dashboard.sh`

Expected: failure with `missing KEDA dashboard`.

- [ ] **Step 3: Keep the executable test for the dashboard implementation**

Run: `chmod +x compose/tests/test-scalecart-worker-keda-dashboard.sh`

- [ ] **Step 4: Commit after the dashboard is green**

```bash
git add compose/tests/test-scalecart-worker-keda-dashboard.sh \
  compose/stacks/observability/grafana/dashboards/Monitoring/scalecart_worker_keda_demo.json
git commit -m "feat: add ScaleCart Worker KEDA demo dashboard"
```

### Task 2: Create the Worker KEDA dashboard

**Files:**
- Create: `compose/stacks/observability/grafana/dashboards/Monitoring/scalecart_worker_keda_demo.json`
- Test: `compose/tests/test-scalecart-worker-keda-dashboard.sh`

**Interfaces:**
- Consumes: the central Prometheus datasource UID `prometheus` and the `cluster` dashboard variable.
- Produces: Grafana UID `scalecart-worker-keda-demo` with four rows of KEDA flow and placement-capacity evidence.

- [ ] **Step 1: Define the shared selector and worker HPA expressions**

Use the existing variable pattern:

```json
{
  "name": "cluster",
  "label": "Cluster",
  "type": "query",
  "datasource": { "type": "prometheus", "uid": "prometheus" },
  "definition": "label_values(kube_horizontalpodautoscaler_status_desired_replicas{namespace=\"scalecart\",horizontalpodautoscaler=\"keda-hpa-scalecart-worker\"}, cluster)",
  "includeAll": true,
  "allValue": ".*",
  "multi": true,
  "refresh": 1
}
```

Use these expressions for Worker state:

```promql
kube_horizontalpodautoscaler_status_current_replicas{namespace="scalecart",horizontalpodautoscaler="keda-hpa-scalecart-worker",cluster=~"$cluster"}
kube_horizontalpodautoscaler_status_desired_replicas{namespace="scalecart",horizontalpodautoscaler="keda-hpa-scalecart-worker",cluster=~"$cluster"}
kube_deployment_status_replicas_available{namespace="scalecart",deployment="scalecart-worker",cluster=~"$cluster"}
```

- [ ] **Step 2: Add the scaling and event-flow panels**

Implement the following PromQL in stat and time-series panels:

```promql
scalecart:worker_kafka_lag:max{cluster=~"$cluster"}

sum by(cluster) (rate(scalecart_orders_produced_total{namespace="scalecart",cluster=~"$cluster"}[1m]))
sum by(cluster) (rate(scalecart_orders_consumed_total{namespace="scalecart",cluster=~"$cluster"}[1m]))

sum by(cluster) (kube_pod_status_phase{namespace="scalecart",pod=~"scalecart-worker-.*",phase="Pending",cluster=~"$cluster"})
or on(cluster) (
  kube_horizontalpodautoscaler_status_desired_replicas{namespace="scalecart",horizontalpodautoscaler="keda-hpa-scalecart-worker",cluster=~"$cluster"} * 0
)
```

Configure the lag panels with threshold `50`. Configure `KEDA Scale-out
Requested` as a boolean comparison of Worker desired replicas greater than
two:

```promql
kube_horizontalpodautoscaler_status_desired_replicas{namespace="scalecart",horizontalpodautoscaler="keda-hpa-scalecart-worker",cluster=~"$cluster"} > bool 2
```

Include the panel description: `Derived from KEDA HPA desired replicas;
the exact ScaledObject Active condition is shown by the ScaleCart Dashboard.`

- [ ] **Step 3: Add actual worker-node utilisation and request reservation panels**

Use `instance` for node-exporter CPU and memory panels, and `node` for
kube-state-metrics request panels:

```promql
1 - avg by(cluster, instance) (
  rate(node_cpu_seconds_total{cluster=~"$cluster",instance=~"worker[0-9]+",mode="idle"}[1m])
)

1 - (
  node_memory_MemAvailable_bytes{cluster=~"$cluster",instance=~"worker[0-9]+"}
  /
  node_memory_MemTotal_bytes{cluster=~"$cluster",instance=~"worker[0-9]+"}
)

sum by(cluster, node) (kube_pod_container_resource_requests{cluster=~"$cluster",node=~"worker[0-9]+",resource="cpu",unit="core"})
/
sum by(cluster, node) (kube_node_status_allocatable{cluster=~"$cluster",node=~"worker[0-9]+",resource="cpu",unit="core"})

sum by(cluster, node) (kube_pod_container_resource_requests{cluster=~"$cluster",node=~"worker[0-9]+",resource="memory",unit="byte"})
/
sum by(cluster, node) (kube_node_status_allocatable{cluster=~"$cluster",node=~"worker[0-9]+",resource="memory",unit="byte"})
```

Set each ratio panel to Grafana `percentunit` with min `0` and max `1`.

- [ ] **Step 4: Add additional Worker slot and node-placement panels**

Use these PromQL expressions:

```promql
floor((
  sum by(cluster, node) (kube_node_status_allocatable{cluster=~"$cluster",node=~"worker[0-9]+",resource="cpu",unit="core"})
  - sum by(cluster, node) (kube_pod_container_resource_requests{cluster=~"$cluster",node=~"worker[0-9]+",resource="cpu",unit="core"})
) / 0.25)

floor((
  sum by(cluster, node) (kube_node_status_allocatable{cluster=~"$cluster",node=~"worker[0-9]+",resource="memory",unit="byte"})
  - sum by(cluster, node) (kube_pod_container_resource_requests{cluster=~"$cluster",node=~"worker[0-9]+",resource="memory",unit="byte"})
) / 536870912)

sum by(cluster) (kube_node_status_condition{cluster=~"$cluster",node=~"worker[0-9]+",condition="Ready",status="true"})
sum by(cluster) (kube_node_spec_taint{cluster=~"$cluster",effect="NoSchedule"})
```

Add a text panel that states: `Actual node CPU can be low while request
reservation is full. The Scheduler places a Worker only when its 250m CPU and
512Mi memory requests fit on one schedulable worker node.`

- [ ] **Step 5: Run the dashboard contract test**

Run: `bash compose/tests/test-scalecart-worker-keda-dashboard.sh`

Expected: `SCALECART_WORKER_KEDA_DASHBOARD=PASS`.

### Task 3: Provision and verify the dashboard on acer-mgmt

**Files:**
- Modify: no repository provisioning file; the existing provider scans the dashboard directory every 30 seconds.
- Test: `compose/tests/test-scalecart-worker-keda-dashboard.sh`

**Interfaces:**
- Consumes: the bind-mounted `acer-mgmt` checkout at `/home/user1/acer-mgmt` and Grafana dashboard provider path `/var/lib/grafana/dashboards`.
- Produces: a Grafana dashboard visible in the Monitoring folder with UID `scalecart-worker-keda-demo`.

- [ ] **Step 1: Validate JSON and contract locally**

Run:

```bash
jq empty compose/stacks/observability/grafana/dashboards/Monitoring/scalecart_worker_keda_demo.json
bash compose/tests/test-scalecart-worker-keda-dashboard.sh
```

Expected: JSON exits zero and the contract prints
`SCALECART_WORKER_KEDA_DASHBOARD=PASS`.

- [ ] **Step 2: Synchronize the merged main revision to acer-mgmt**

Run:

```bash
ssh acer-mgmt 'git -C /home/user1/acer-mgmt pull --ff-only origin main'
```

Expected: the live checkout contains the dashboard JSON.

- [ ] **Step 3: Verify Grafana sees the provisioned dashboard**

Run:

```bash
ssh acer-mgmt 'sudo -n docker exec grafana \
  wget -qO- http://localhost:3000/api/search?query=ScaleCart%20Worker%20KEDA%20Demo'
```

Expected: JSON containing UID `scalecart-worker-keda-demo`.

- [ ] **Step 4: Verify GGG PromQL panel inputs**

Run a Grafana Explore query for each panel family with `cluster="ggg"`:

```promql
scalecart:worker_kafka_lag:max{cluster="ggg"}
kube_horizontalpodautoscaler_status_desired_replicas{cluster="ggg",namespace="scalecart",horizontalpodautoscaler="keda-hpa-scalecart-worker"}
sum by(cluster, node) (kube_pod_container_resource_requests{cluster="ggg",node=~"worker[0-9]+",resource="cpu",unit="core"})
```

Expected: each query returns a GGG series; an idle Pending Worker panel
returns zero rather than `No data`.
