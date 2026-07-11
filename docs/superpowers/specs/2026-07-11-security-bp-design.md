# ACER Management Security Best-Practice Design

## Goal

Make Keycloak the human identity source, Teleport the privileged-access gateway,
Vault the secret source, Elasticsearch/Kibana the shared audit investigation
surface, and Wazuh the host-security detector without duplicating those roles.

## Identity and access boundaries

| Boundary | Control | Policy |
|---|---|---|
| Team portal and low-risk web UIs | oauth2-proxy + Keycloak | The proxy is the only OIDC client for Dashy, n8n, and Uptime Kuma. |
| Applications with native RBAC | Native Keycloak OIDC | Grafana, GitLab, NetBox, Argo CD, and Supabase retain their native OIDC flows. |
| Privileged interactive access | Teleport Community local MFA | SSH and privileged management UIs use Teleport. Keycloak is not chained behind Teleport in Community Edition. |
| Automation | Vault machine auth | AppRole, Kubernetes auth, and service credentials never use browser SSO. |
| Recovery | Local service administrators | Local `admin` accounts are break-glass only and are never linked from the portal. |

The canonical human URL for a privileged UI redirects to its `tp-` application
address. The direct backend Docker service remains reachable only on internal
networks for service-to-service operation. Keycloak discovery/token endpoints,
non-HTTP APIs, and data-plane protocols are never redirected through Teleport.

## Authorization model

Keycloak groups express least privilege. Existing `platform-admin` remains a
temporary compatibility group, but service-specific groups are authoritative:

| Group | Target role |
|---|---|
| `grafana-editor` | Grafana Editor |
| `netbox-editor` | NetBox local RBAC group (its object permissions define editor scope) |
| `netbox-admin` | NetBox superuser |
| `argocd-deployer` | Argo CD application sync/update |
| `argocd-admin` | Argo CD administrator |

`platform-admin` is accepted as a compatibility administrator mapping during
the migration. The provisioning script creates the groups and the NetBox login
pipeline maps only explicit NetBox groups plus the compatibility group. GitLab
continues to block newly auto-created OIDC users until a GitLab administrator
approves and places them in the appropriate GitLab group.

## Audit design

Native audit sources remain authoritative:

* Vault keeps file and socket audit devices.
* Teleport keeps events and session recordings.
* Keycloak stores user and administrator events.
* Wazuh keeps endpoint detection data in its own indexer.

Filebeat sends security event files and container logs to Logstash. Logstash
normalizes fields to ECS-compatible `event.*`, `user.*`, `source.*`,
`service.name`, `resource.name`, and `labels.audit_source` fields. Vault's two
audit devices are deduplicated by request ID and record type. Elasticsearch
receives canonical audit documents under a dedicated `acer-audit-*` index
family; Kibana is the investigation UI, while Grafana only consumes aggregate
security metrics.

## Wazuh design

Wazuh manager, indexer, and dashboard run as an all-in-one Compose stack on
`acer-mgmt`. Native host agents run on `acer-mgmt` and `acer-aio`; they use
outbound encrypted agent connections over Tailscale. The agents inspect host
authentication logs, packages, selected configuration paths, and Docker/Kolla
metadata. They exclude Vault data, Vault Agent rendered secrets, TLS private
keys, OpenStack passwords, kubeconfigs, Terraform state, and database dumps.

Wazuh alerts, rather than all raw Wazuh events, are forwarded to Logstash for
Kibana correlation. Falco remains responsible for Kubernetes runtime detection.

## Verification requirements

* Shell tests prove all declared policy boundaries and collectors.
* Compose config validates every changed stack.
* Live checks prove Keycloak groups/events, Teleport app registration, Filebeat
  harvesters, Logstash indexing, Wazuh agent enrollment, and health endpoints.
* Direct privileged URLs redirect to Teleport or are otherwise denied.
* No secret value appears in repository files, logs, dashboards, or tests.
