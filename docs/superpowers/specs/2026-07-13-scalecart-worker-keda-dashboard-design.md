# ScaleCart Worker KEDA Demo Dashboard Design

## Goal

Provide one provisioned Grafana dashboard for the D03 Worker/KEDA recording
flow. It must show the causal path from Kafka backlog through KEDA scale-out
to either Ready Worker capacity or Kubernetes scheduling pressure.

## Scope

- Create one Monitoring-folder dashboard named `ScaleCart Worker KEDA Demo`.
- Keep the existing `ScaleCart API HPA Load Demo` and `ScaleCart SRE Landing`
  unchanged.
- Support the existing multi-cluster `cluster` selector.
- Use only metrics already available in central Prometheus; do not add a new
  exporter, alert, KEDA configuration, or workload change.

## Observability Boundary

Central Prometheus currently has Kafka lag, Kubernetes HPA and Pod state,
node-exporter CPU and memory metrics, node resource request/allocatable
metrics, node Ready state and node taints. It does not have a raw
`ScaledObject Active=True` metric.

The dashboard therefore must not label a derived value as `KEDA Active`.
Instead it presents `KEDA Scale-out Requested`, defined as the Worker KEDA HPA
desired replica count exceeding its configured minimum of two. The ScaleCart
Dashboard and `kubectl get scaledobject` remain the authoritative source for
the exact ScaledObject Active condition.

## Dashboard Layout

### Row 1: Scaling summary

1. **Kafka Lag** — `scalecart:worker_kafka_lag:max`; threshold 50.
2. **Worker Ready / Desired** — Deployment available replicas and KEDA HPA
   desired replicas, rendered as `ready / desired`.
3. **KEDA Scale-out Requested** — boolean derived from KEDA HPA desired
   replicas greater than two; labels must describe this derivation.
4. **Pending Worker Pods** — pending `scalecart-worker-*` Pods.

### Row 2: Event flow

1. **Kafka Lag and Threshold** — lag time series with a fixed threshold line
   at 50.
2. **Order Produce / Consume Rate** — rates of
   `scalecart_orders_produced_total` and `scalecart_orders_consumed_total`.
3. **Worker Replica Timeline** — KEDA HPA current and desired replicas plus
   Deployment available replicas.

### Row 3: Scheduling evidence

1. **Worker Node Actual CPU** — per worker node, calculated from non-idle
   `node_cpu_seconds_total` over one minute.
2. **Worker Node CPU Request Reservation** — per worker node, total Pod CPU
   requests divided by allocatable CPU.
3. **Worker Node Actual Memory** — per worker node, used memory divided by
   total memory.
4. **Worker Node Memory Request Reservation** — per worker node, total Pod
   memory requests divided by allocatable memory.

### Row 4: Placement capacity

1. **Additional Worker Slots by CPU** — floor of available requested CPU
   capacity divided by the Worker CPU request (250m).
2. **Additional Worker Slots by Memory** — floor of available requested
   memory capacity divided by the Worker memory request (512Mi).
3. **Node Placement Status** — Ready worker-node count and NoSchedule-tainted
   node count. This distinguishes master-taint exclusion from worker capacity
   exhaustion.
4. **Demo Reading Guide** — short text explaining that actual node CPU and
   request reservation are different signals.

## PromQL Contract

- Filter all workload and Kubernetes metrics by `cluster=~"$cluster"` and
  `namespace="scalecart"` where applicable.
- Filter node capacity panels to `instance=~"worker[0-9]+"` or matching
  `node` labels so a control-plane NoSchedule taint is not mistaken for an
  available Worker placement target.
- Use one-minute `rate()` windows for CPU and order throughput.
- Use percent units for ratios in the `0..1` range, not `0..100`.
- Show zero for missing pending Worker series via a zero fallback so idle
  demonstrations do not render `No data`.

## Demo Acceptance Criteria

During the D03 campaign, an operator can show:

```text
Kafka lag rises above 50
→ Worker KEDA HPA desired replicas rises above two
→ pending count and node request reservation explain placement outcome
→ Worker consume rate and available replicas show recovery progress
```

At idle, the dashboard shows lag zero, desired Worker replicas two, no pending
Workers, and valid per-node actual-versus-request capacity panels.

## Verification

- A JSON contract test validates dashboard UID, title, cluster variable,
  panel titles, PromQL metric families, 50-lag threshold, Worker request
  constants, and zero fallback for pending Pods.
- `jq empty` validates the dashboard JSON.
- Grafana provisioning is verified on `acer-mgmt` by confirming the dashboard
  is listed and its panels return GGG series without query errors.
