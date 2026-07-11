# Operator-only Uptime Kuma Status Design

## Goal

Add Uptime Kuma as a small, operator-only status board on `acer-mgmt`.  It
answers the outside-in question, "can an operator reach this important
endpoint now?" It does not replace the existing Prometheus, Blackbox Exporter,
Alertmanager, or Grafana observability stack.

The initial board shows management services plus two monitor types for every
team cluster. The management-service monitors are:

1. Grafana: `https://grafana.${BASE_DOMAIN}/api/health`
2. Prometheus: `https://prometheus.${BASE_DOMAIN}/-/healthy`
3. Alertmanager: `https://alertmanager.${BASE_DOMAIN}/`
4. GGG Kubernetes API proxy: `https://ggg-operator.tailc0244b.ts.net/livez`

The first three are already active Blackbox targets. Kuma displays their
state; Alertmanager remains the only paging path for those existing checks.

For `nmg`, `ggg`, `oje`, `khb`, and `ljw`, create two HTTP monitors each:

1. `Kubernetes API /livez`: `https://<team>-operator.tailc0244b.ts.net/livez`
2. `ScaleCart dashboard`: `https://<team>.${BASE_DOMAIN}/`

The API monitor covers the supported Tailscale management path. The dashboard
monitor covers the user-facing Cloudflare/ingress path. A failed monitor is a
real signal, not an installation error: at design verification time, `nmg` and
`ggg` returned HTTP 200 for both paths, while `oje`, `khb`, and `ljw` timed out
on `/livez` and returned HTTP 530 for the dashboard path.

## Chosen Design

Run one Uptime Kuma Compose service on `acer-mgmt`, connected only to the
existing external Docker network `mgmt-proxy` and its project-default network.
Traefik exposes its UI at `kuma.${BASE_DOMAIN}` over the existing HTTPS entry
point and applies the existing `sso-auth@file` forward-auth middleware. There
is no public status page in this change.

```text
operator -> Traefik HTTPS + SSO -> Uptime Kuma (acer-mgmt)
                                      |-- Grafana health endpoint
                                      |-- Prometheus health endpoint
                                      |-- Alertmanager endpoint
                                      |-- five Tailscale API proxies /livez
                                      `-- five team dashboard HTTPS paths

Prometheus + Blackbox Exporter -> Alertmanager -> official alerts
Prometheus agents in Kubernetes -> node, kubelet, pod, and object metrics
```

Uptime Kuma persists its SQLite data, monitor definitions, history, and local
administrator credentials under `${DATA_ROOT:-/home/mgmt-data}/uptime-kuma`.
The existing Restic source mount already covers `DATA_ROOT`, so this state is
included in the normal encrypted backup flow.

## Alternatives Considered

### Central Kuma on `acer-mgmt` (chosen)

One deployment sees the same management and user-facing paths that operators
use. It adds no workload to `acer-aio`, OpenStack Nova VMs, or Kubernetes
nodes, and it follows the current Traefik/data-root patterns.

### Kuma inside each Kubernetes cluster

This would require a Deployment, persistent volume, ingress, and maintenance
in every cluster. It duplicates node, kubelet, and object observation already
provided by `node-exporter`, `kube-state-metrics`, and `prometheus-agent`.
It is not justified for the initial status board.

### Use Kuma instead of Prometheus/Blackbox/Alertmanager

Rejected. Kuma does not provide the existing node resource metrics, Kubernetes
object state, time-series/SLO calculations, or authoritative alert routing.

## Security and Network Decisions

- Do not publish a host port. Traefik is the sole ingress path.
- Do not mount `/var/run/docker.sock`; Docker container inspection would grant
  unnecessarily broad host control.
- Protect the Kuma UI with the existing Keycloak-backed `sso-auth@file`
  middleware. Kuma's initial local administrator is created interactively and
  its password hash remains only in the persistent application data.
- Keep the status page private. A future public page is a separate decision
  because it changes what infrastructure details are disclosed.
- Do not add direct `mgmt -> 10.20.0.0/24` routing or open node security-group
  ports for Kuma. The GGG API proxy is the supported management path.
- Kuma monitors must not contain tokens, passwords, or authenticated headers
  in Git. Protected endpoints require an explicit future secret design.

## Repository-owned Changes

- `compose/stacks/observability/uptime-kuma/compose.yaml`: the one-service
  Compose stack, persistence, health check, Traefik/SSO labels, and
  `mgmt-proxy` attachment.
- `compose/tests/test-uptime-kuma-stack.sh`: static contract test for image,
  no host port, persistent data, TLS router, SSO middleware, health check, and
  absence of a Docker socket mount.
- `compose/stacks/edge/homepage/config/services.yaml`: a private Homepage link
  named `Uptime Kuma`.
- `docs/runbooks/uptime-kuma-2026-07-11.md`: deployment, initial administrator
  setup, the 13-monitor inventory, monitor ownership, backup, validation, and
  rollback instructions.

No `acer-aio`, OpenStack, or Kubernetes manifest changes belong to this scope.

## Resource and Failure Model

The new permanent runtime resource is one Compose container on `acer-mgmt`
plus its data directory. It uses `restart: unless-stopped` and an HTTP health
check. No database, Redis, agent, DaemonSet, or Kubernetes persistent volume
is added.

If Kuma fails, it affects only the operator status board. Existing Blackbox
checks and Alertmanager notifications continue independently. If a monitored
endpoint fails, Kuma records the incident but does not create an additional
notification for the initial management-service targets. This prevents
duplicate paging.

## Acceptance Criteria

1. `docker compose config` renders the Kuma stack without unresolved required
   values and the static stack test passes.
2. On `acer-mgmt`, the container is healthy and only exposes its UI through
   Traefik HTTPS at `kuma.${BASE_DOMAIN}`.
3. An unauthenticated UI request is intercepted by the existing SSO flow;
   no direct host port or public status page is available.
4. The initial local Kuma administrator can sign in after SSO, and all 13
   named monitors are enabled without credentials stored in Git.
5. The Grafana, Prometheus, Alertmanager, five team API `/livez`, and five
   team dashboard monitors show the same outcome as independent direct checks
   from `acer-mgmt`.
6. Existing Prometheus Blackbox targets and Alertmanager rules remain loaded
   and produce no duplicate Kuma notification path.
7. `${DATA_ROOT}/uptime-kuma` has the expected SELinux container label and is
   included in the existing Restic source tree.
8. The new Homepage link resolves through the SSO-protected Kuma route.

## Rollback

Stop and remove only the Kuma Compose service and its Traefik/Homepage
configuration. Keep `${DATA_ROOT}/uptime-kuma` until an operator explicitly
approves data deletion; it contains monitor history and the local account
state. Rollback does not change Prometheus, Blackbox Exporter, Alertmanager,
OpenStack, or any Kubernetes resource.
