# Dashy Docker Runtime Design

## Goal

Add a read-only Docker Runtime page to ACER Operations. It must show a live
health summary for each Compose stack, allow each stack to expand into its
containers, and run inside Dashy's workspace iframe without granting Dashy or
the browser access to the Docker socket.

## Scope

The first delivery covers the Docker Engine on `acer-mgmt` only. Its fixed
stack groups are Observability, Security, Data, CI/CD, Edge, and Backup. A
container belongs to a group through its `com.docker.compose.project` label;
the configuration maps project names to one of these groups.

The Docker Runtime page is for observation. It does not start, stop, restart,
remove, exec into, create, or reconfigure containers. It does not expose
container environment variables, bind mounts, labels other than the Compose
project, Docker networks, image digests, or Docker events to the browser.

Portainer is intentionally out of scope. If operations later require a
container console or lifecycle actions, Portainer will be added as a separate
admin-only application rather than expanding this read-only page.

## User Experience

Dashy retains the Service Index as a list of human-accessible application UIs.
It gains a `Docker Runtime` navigation item that opens a dedicated page in
Dashy's `workspace` view. The new page has one summary card per stack:

```text
Observability  6/6 healthy  ▼
Security       5/6 healthy  ▶
Data           12/12 healthy ▶
CI/CD           8/8 healthy  ▶
Edge            4/4 healthy  ▶
Backup          2/2 healthy  ▶
```

The count is a live value, not a manually maintained label. Selecting a stack
expands an accessible accordion below its summary. Each child row contains the
container name, its current state, its Docker health status when the image has
a healthcheck, and its role. A container with no Docker healthcheck is shown
as `running (no healthcheck)`; it is not silently counted as healthy.

The stack summary uses the following states:

| State | Meaning |
| --- | --- |
| healthy | Container is running and its defined healthcheck is `healthy` |
| running | Container is running but declares no healthcheck |
| unhealthy | Container is running and its defined healthcheck is `unhealthy` or `starting` |
| unavailable | Docker returned no current state for the container |
| stopped | Container is not running |

`healthy total` counts only healthy containers. A group containing containers
with no healthcheck therefore displays, for example, `8 healthy / 12 total`,
which accurately distinguishes running from verified healthy. The UI also
shows separate `running` and `attention` counts so an operator can identify
the gap without opening the group.

## Architecture

```text
Browser
  -> Dashy workspace iframe
  -> Traefik + oauth2-proxy + Keycloak platform-admin gate
  -> Docker Runtime Viewer
  -> read-only Docker socket proxy (internal Docker network only)
  -> /var/run/docker.sock on acer-mgmt
```

The Runtime Viewer is a small internal web service. It calls the socket proxy
only from its server side, reads Docker container summaries and inspect data,
groups results by the configured Compose project map, and returns a rendered
page plus a minimal runtime JSON endpoint for its own browser-side refresh.
No Docker API URL is accessible from the browser.

The socket proxy is not published with a host port and shares a dedicated
internal network only with the Viewer. Its allowlist permits only `GET`/`HEAD`
access required for Docker version, daemon information, container list, and
container inspection. `POST`, `AUTH`, `SECRETS`, `EXEC`, images, networks,
volumes, and all lifecycle endpoints remain denied. The Viewer itself runs as
a non-root user with a read-only filesystem where its runtime permits it.

The Runtime Viewer is published through Traefik at a dedicated HTTPS host,
protected by the existing oauth2-proxy -> Keycloak `platform-admin` policy.
Its response permits framing only by `https://dash.imcherry5778.xyz`; it does
not use a broad `*` frame-ancestor policy. The direct URL stays useful for
troubleshooting but has the same authentication gate.

## Refresh, Failure, and Safety Behavior

The Viewer fetches fresh Docker state every 15 seconds while its page is open.
It returns the last successful snapshot with a timestamp if a later proxy call
fails. If no successful snapshot exists, it renders a clear `Runtime data
unavailable` state and returns HTTP 503 from the JSON endpoint. It never
substitutes stale or failed data with green status counts.

The Viewer has a five-second upstream timeout. A malformed or ungrouped
container is placed in a visible `Other` group rather than being hidden. An
empty configured group remains visible as `0 / 0` so a missing Compose stack
is not confused with a healthy one.

The Viewer must escape every Docker-provided string before rendering it. Logs,
environment values, mount paths, image digests, and full labels are excluded
from both the HTML and JSON responses. The service logs only aggregate request
outcomes and errors, not Docker response bodies.

## Observability Boundaries

Dashy's native `statusCheck` remains responsible for the availability dots on
Service Index cards that have HTTP endpoints. It does not determine Docker
container health. Prometheus, blackbox exporter, and Grafana remain the
authoritative source for endpoint alerting, resource metrics, and long-term
history. The new Viewer supplies current Docker lifecycle state only; it does
not duplicate Prometheus scraping or create alerts.

## Verification Criteria

1. A non-authenticated request to the Runtime Viewer is redirected to the
   existing login flow; a user outside `platform-admin` cannot reach it.
2. An authenticated platform administrator can open the page directly and in
   Dashy's workspace iframe.
3. The Docker socket proxy denies a lifecycle `POST` and allows only the
   Viewer-required read endpoints.
4. The live summary and expanded rows match Docker's current state, including
   `running (no healthcheck)`, `unhealthy`, and stopped cases.
5. Socket-proxy loss displays stale timestamped data or the explicit
   unavailable state, never a fabricated healthy count.
6. Configuration and tests cover all six named groups plus an ungrouped
   container.

## Deferred Work

Container CPU, memory, network, restart history, multi-host aggregation,
Kubernetes workload runtime, and Portainer are deliberately deferred. Those
belong in Grafana, a future multi-host Runtime Viewer extension, or a separate
admin console and are not prerequisites for the first read-only Docker page.
