# ScaleCart API HPA Load Demo Runbook

## Purpose

Run an operator-triggered k6 test from Semaphore and capture ScaleCart API HPA scale-out while Grafana and the ScaleCart Dashboard show the same event.

## Preconditions

- The `acer-mgmt` Semaphore service is running from `acer/semaphore-k6-kubectl:v2.18.25-k6.1.0.0-rc2-kubectl.1.35.6`.
- Grafana has provisioned **ScaleCart API HPA Load Demo**.
- Argo CD has synced the ScaleCart API image containing `apiDeployment` and `apiHpa` observability fields.
- The selected team API HPA is idle at current/desired replicas `2 / 2`.
- Vault Agent has rendered five files at `/home/mgmt-data/vault-agent/secrets/cicd/k6/*.env`. These files are mounted read-only into Semaphore; neither a user JWT nor a k6 key is stored in Semaphore.

## Semaphore task

The reconciler creates one Bash template named **ScaleCart API HPA Load Test** in every team project. Select the project matching the cluster to demonstrate; do not use `acer-mgmt` for a team load test.

| Semaphore project | Target URL | Vault key path |
| --- | --- |
| `acer-aio-ggg` | `https://ggg.imcherry5778.xyz` | `kv/mgmt/k6/ggg` |
| `acer-aio-khb` | `https://khb.imcherry5778.xyz` | `kv/mgmt/k6/khb` |
| `acer-aio-ljw` | `https://ljw.imcherry5778.xyz` | `kv/mgmt/k6/ljw` |
| `acer-aio-nmg` | `https://nmg.imcherry5778.xyz` | `kv/mgmt/k6/nmg` |
| `acer-aio-oje` | `https://oje.imcherry5778.xyz` | `kv/mgmt/k6/oje` |

Only `K6_RATE` and `K6_DURATION` are user-overridable. The runner sources the selected team key file and calls read-only `GET /api/demo/state` with `X-K6-Demo-Key`. The API accepts this key only for that one GET endpoint; all other API routes continue to require a Supabase JWT. k6 ramps from 20 RPS to the configured rate over two minutes, holds the rate, then ramps down over 30 seconds. The task fails when HTTP failures reach 1%, named-endpoint P95 exceeds one second, or checks fall below 99%.

## Demo procedure

1. Open the selected team's ScaleCart Dashboard, its Grafana **ScaleCart API HPA Load Demo**, and that team's Semaphore template run page.
2. Confirm Grafana reports API HPA current and desired replicas as `2` and ScaleCart Dashboard reports `API replicas 2 / 2`.
3. Start the Semaphore task manually. Do not schedule it.
4. In Grafana, record the request-rate/P95 panel, API CPU utilisation panel, and the desired/current replica timeline.
5. In ScaleCart Dashboard, record `API CPU HPA` crossing the configured 70 target and `API replicas` increasing from `2 / 2`.
6. Confirm the k6 task finishes with all thresholds passing. Save the Semaphore task output with the screen recording.
7. After the k6 ramp-down completes, observe HPA scale-in naturally. Keep the dashboard open until desired/current replicas return to `2 / 2`.

## Immediate stop conditions

Press **Stop** in Semaphore and do not restart the test if either condition is observed for two consecutive 30-second checks:

- HTTP error rate is at or above 1%.
- P95 request duration is at or above one second.

Never stop the test by deleting API Pods, changing the HPA minimum/maximum values, or applying a manual replica count. Those actions invalidate the autoscaling evidence.

## Evidence checklist

- Semaphore output: all k6 thresholds pass.
- Grafana: RPS, P95, API CPU, and HPA desired/current replica panels have samples for the same time range.
- ScaleCart Dashboard: API HPA status and Ready/desired API replica values rose above two.
- Kubernetes: `kubectl -n scalecart get hpa scalecart-api -w` captured the desired replica increase and `kubectl -n scalecart get deployment scalecart-api -w` captured Ready Pods.
