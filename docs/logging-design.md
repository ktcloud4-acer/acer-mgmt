# Logging design

## Scope

The central log platform is the ELK stack on `acer-mgmt`:

- Elasticsearch, Logstash, Kibana: 9.4.x
- Kibana Spaces are used for operator convenience, not for security isolation.
- Metrics and FinOps stay in Prometheus, Grafana, and OpenCost.
- Tracing is out of scope unless OpenTelemetry and Tempo are introduced later.

## Important constraints

1. A single Filebeat process has one output. If one host must send Linux system
   logs directly to Elasticsearch and Docker logs through Logstash, run two
   Filebeat instances with different configs and data paths.
2. Elasticsearch currently listens on `127.0.0.1:9200` on `acer-mgmt`.
   Remote hosts must not send directly to Elasticsearch unless Elasticsearch is
   secured and intentionally exposed on a private interface.
3. Linux system logs should not mean `/var/log/**`. Collect only the OS files
   needed for operational and security visibility:
   - RHEL/Rocky: `/var/log/messages`, `/var/log/secure`
   - Ubuntu/Debian: `/var/log/syslog`, `/var/log/auth.log`
4. Docker, Kubernetes container, OpenStack Kolla, and custom application logs
   need explicit routing and metadata. They go through Logstash.
5. Spaces organize dashboards and data views. Data access isolation requires
   Elasticsearch security roles, which is not the current goal.

## Target flow

```text
acer-mgmt Linux system logs
  Filebeat system module -> Elasticsearch
  Purpose: keep Filebeat System dashboards simple.

acer-mgmt Docker and k3d logs
  Filebeat side instance -> Logstash -> Elasticsearch

acer-aio Linux system and OpenStack Kolla logs
  Filebeat -> Logstash -> Elasticsearch
  Current runtime: Dockerized Filebeat 9.4.2 with host networking because
  the AIO Docker daemon disables bridge IP forwarding.

Kubernetes node system logs and container logs
  Filebeat DaemonSet -> Logstash -> Elasticsearch
```

## Index naming

New custom logs use daily indices:

```text
logs-system-<team>-YYYY.MM.dd
logs-docker-<team>-YYYY.MM.dd
logs-k3d-<team>-YYYY.MM.dd
logs-kubernetes-<team>-YYYY.MM.dd
logs-openstack-<team>-YYYY.MM.dd
logs-service-<team>-YYYY.MM.dd
```

The direct `acer-mgmt` Filebeat system module keeps the default Filebeat data
stream so prebuilt dashboards continue to work:

```text
filebeat-9.4.2
```

## Required common fields

Every custom log event should carry these fields where applicable:

```text
labels.team
labels.platform
labels.node_role
labels.log_type
host.name
event.dataset
service.name
kubernetes.namespace
kubernetes.pod.name
container.name
```

`labels.team` maps to dashboard grouping and Space convenience:

```text
mgmt | aio | nmg | oje | khb | ljw | ggg
```

`labels.log_type` values:

```text
system | docker | k3d | kubernetes | openstack | service
```

## Runtime notes

- `acer-mgmt` runs the packaged `filebeat.service` for Linux system logs.
- `acer-mgmt` runs `acer-mgmt-filebeat-docker.service` as a second Filebeat
  instance for Docker logs. Its data path is `/var/lib/filebeat-docker`.
- `acer-aio` runs a Dockerized Filebeat container named `filebeat-aio`.
  It uses `--network host` so it can reach the mgmt Tailscale Logstash
  listener at `100.117.59.96:5044`.
- First-time migration can ingest historical logs. After the registry is
  populated, Filebeat continues incrementally.

## Space model

Spaces are presentation boundaries:

- `MGMT`: `labels.team: mgmt`, mgmt host, Docker, k3d, observability logs.
- `nmg`, `oje`, `khb`, `ljw`, `ggg`: team Kubernetes and related logs.
- `Default`: admin/global exploration.

Each Space should own its own data views and dashboard copies. A Space does not
hide data by itself when Elasticsearch security is disabled.
