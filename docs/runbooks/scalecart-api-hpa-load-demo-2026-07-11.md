# ScaleCart API HPA Load Demo Runbook

## Purpose

Run an operator-triggered k6 test from Semaphore and capture ScaleCart API HPA scale-out while Grafana and the ScaleCart Dashboard show the same event.

## Preconditions

- The `acer-mgmt` Semaphore service is running from `acer/semaphore-k6:v2.18.25-k6.1.0.0-rc2`.
- Grafana has provisioned **ScaleCart API HPA Load Demo**.
- Argo CD has synced the ScaleCart API image containing `apiDeployment` and `apiHpa` observability fields.
- API HPA is idle at current/desired replicas `2 / 2`.
- A current, protected `K6_ACCESS_TOKEN` with the ScaleCart `authenticated` audience is stored in Semaphore. Do not put the token in Git, a task log, or a command-line argument.

## Semaphore task

Create a Bash template in the `acer-mgmt` project.

| Setting | Value |
| --- | --- |
| Template name | `load:scalecart-api-hpa` |
| Repository | `acer-mgmt` on `main` |
| Playbook | `compose/scripts/k6/run-scalecart-api-hpa.sh` |
| `K6_BASE_URL` | `https://nmg.imcherry5778.xyz` |
| `K6_RATE` | `150` |
| `K6_DURATION` | `4m` |
| `K6_ACCESS_TOKEN` | protected Semaphore secret |

The script targets the authenticated, read-only `GET /api/demo/state` endpoint. It ramps from 20 RPS to the configured rate over two minutes, holds the rate, then ramps down over 30 seconds. The task fails when HTTP failures reach 1%, named-endpoint P95 exceeds one second, or checks fall below 99%.

## Demo procedure

1. Open the ScaleCart Dashboard, Grafana **ScaleCart API HPA Load Demo**, and the Semaphore template run page.
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
