# Runtime Health Classification Design

## Goal

Make Docker Runtime Viewer distinguish verified container health from an
unchecked running process, show completed and failed one-shot containers, and
assign every current management-host container to an operational group.

## Scope

The viewer remains a Docker lifecycle view. Prometheus Blackbox checks and
Alertmanager remain the authority for externally reachable service health.

## Status Model

| Runtime status | Meaning | Summary treatment |
| --- | --- | --- |
| `healthy` | Docker healthcheck is present and passing | healthy |
| `unchecked` | Container is running without a healthcheck | unchecked; not an alert |
| `starting` | Healthcheck has not passed yet | attention |
| `unhealthy` | Healthcheck is failing | attention |
| `completed` | One-shot/init container exited with code 0 | completed; not an alert |
| `failed` | Container exited with a non-zero code | attention |

`running` is retained only as the Docker API input condition; the viewer
normalizes it to `unchecked` when the container has no healthcheck.

## Group Model

The viewer uses an explicit grouping configuration with Compose project names
and exact container-name or name-prefix rules for unmanaged containers.

| Group | Assignments added or retained |
| --- | --- |
| Observability | Prometheus, exporters, Grafana, ELK, Tempo, n8n |
| Security | Keycloak, oauth2-proxy, Vault, Teleport, Wazuh |
| Data | Kafka, NetBox, Supabase, `pg-tailnet-proxy` |
| CI/CD | GitLab, Runner, Harbor, Semaphore, SonarQube, Allure, Playwright |
| Edge | Traefik, Dashy, AdGuard |
| Backup | MinIO, Restic |
| Infra | `k3d-mgmt-server-*` |
| Operations | Runtime Viewer, Docker Socket Proxy, Platform Monitor |

The UI must only expose an `Unclassified` group when a newly introduced
container has no matching explicit rule. It is an operator signal, not a
normal operating group.

## Healthcheck Policy

Add native Docker healthchecks only where the check meaningfully verifies
readiness without credentials or harmful side effects:

- Exporters and HTTP proxies: official health/metrics/ping endpoint returning
  HTTP success.
- Web APIs and UIs: their documented readiness endpoint.
- Datastores: vendor-native readiness commands such as `pg_isready` or
  `redis-cli ping` where the image includes the command.

Do not add artificial healthchecks to init jobs, migration jobs, one-shot
containers, or workers/sidecars lacking a meaningful local readiness signal.
Those remain `completed` or `unchecked`.

## Error Handling and Presentation

Summary cards show independent counts such as `11 healthy · 2 unchecked · 1
completed`; attention is reserved for `starting`, `unhealthy`, and `failed`.
Expanded rows show the normalized status and the Compose service role.

## Validation

- Unit tests cover normalization, `failed` and `completed` status counts, and
  project/container-name group mapping.
- Static tests ensure known non-Compose containers have explicit mappings.
- Compose configuration checks validate new healthcheck commands.
- Runtime API verification confirms no current container is placed in
  `Unclassified` and that completed init jobs remain in their owning group.
