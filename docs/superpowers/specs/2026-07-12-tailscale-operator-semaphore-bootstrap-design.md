# Tailscale Operator Semaphore Bootstrap Design

## Goal

Use the existing `acer-aio-nmg` Semaphore project to restore a freshly rebuilt
NMG cluster's Tailscale Kubernetes API endpoint, renew its Argo CD credential,
and let central Argo CD reconcile the existing NMG applications. The same
design must be reusable for GGG, KHB, LJW, and OJE after the NMG pilot passes.

## Current state and problem

Replacing the NMG Nova instances recreated the kubeadm control plane. The new
cluster has no Tailscale Operator, while Argo CD's `cluster-nmg` Secret contains
the prior cluster's service-account token and API CA. The configured destination
`https://nmg-operator.tailc0244b.ts.net` consequently resolves to an offline
old tailnet node. Argo CD can display a cached `Healthy` status although the
new cluster has none of the corresponding resources.

## Decision

Implement a manually started, platform-admin-only Semaphore template named
`Bootstrap Tailscale Operator and Argo CD` in `acer-aio-nmg`. It is not a
schedule and it is not available to ordinary workload namespaces. It bootstraps
the selected cluster through its direct recovery kubeconfig, then returns
control to the existing GitOps path.

The operator is a cluster-wide component installed in the target cluster's
`tailscale` namespace. A Semaphore project chooses the target cluster; it does
not install the operator in the team's `scalecart` namespace.

## Secret and access model

Vault is the only source of long-lived secrets.

| Vault KV path | Fields | Consumer | Purpose |
| --- | --- | --- | --- |
| `mgmt/tailscale/operators/nmg` | `oauth_client_id`, `oauth_client_secret` | NMG bootstrap task only | Installs the NMG Operator. |
| `mgmt/tailscale/bootstrap/nmg` | `kubeconfig_b64` | NMG bootstrap task only | Direct FIP recovery access before a tailnet API endpoint exists. |
| `mgmt/argocd/clusters/nmg` | `name`, `server`, `config` | Management ESO | Existing Argo CD cluster Secret source. |

The task obtains the first two values through a Vault AppRole whose policy can
read only the two NMG paths. The task never receives the management Vault root
token. OAuth values, kubeconfig data, bearer tokens, and CA data are never
written to Git, Semaphore survey variables, task output, or shell tracing.
Semaphore project permissions must permit platform administrators to execute
the fixed template but not let team members edit its repository/playbook or
environment.

Each later team receives a distinct OAuth client and a distinct Vault AppRole;
there is no shared tailnet write credential. The OAuth client must have only
the Tailscale operator permissions required for its own tags: write access to
General/Services, Devices/Core, and Keys/Auth Keys. The tailnet ACL makes the
team operator tag an owner only of that team's proxy tag.

## NMG execution flow

1. An administrator starts the NMG Semaphore template manually.
2. The task creates a `0600` temporary recovery kubeconfig from
   `mgmt/tailscale/bootstrap/nmg`; its API server is the NMG direct recovery
   address, not the stale Tailscale hostname.
3. The task uses Helm to install or upgrade the pinned Tailscale Kubernetes
   Operator in namespace `tailscale`, using only the NMG OAuth credentials.
4. The task applies a `ProxyGroup` named `nmg-operator`, type
   `kube-apiserver`, with `spec.kubeAPIServer.hostname: nmg-operator` and
   `mode: noauth`. The `noauth` transport preserves the existing Argo CD bearer
   token authentication model; it does not grant unauthenticated Kubernetes
   access because the API server still validates the bearer token.
5. After the ProxyGroup reports `ProxyGroupReady`, the task issues a fresh
   least-privilege `argocd-manager` service-account credential in the target
   cluster and builds the Argo CD `config` JSON with the proxy's full HTTPS URL
   and its CA data.
6. The task writes only the three Argo cluster fields (`name`, `server`,
   `config`) to `mgmt/argocd/clusters/nmg`, preserving the path contract used by
   the management ExternalSecret.
7. The task forces the management `argocd-cluster-nmg` ExternalSecret refresh,
   waits for `cluster-nmg` to change, then requests Argo CD reconciliation of
   each NMG Application. It verifies the new cluster contains the Tailscale
   components, Cinder CSI, and the expected application namespaces.
8. Shell traps delete temporary kubeconfig, token, and rendered OAuth files on
   both success and failure. The final task output contains only target name,
   resource readiness, and Argo application health summaries.

## Reconciliation boundaries

The first run is NMG-only. It restores the GitOps control path but does not
change any workload manifests, default StorageClass, Cinder quota, or existing
Cloudflare tunnel configuration. Argo CD remains the owner of workload
resources after bootstrap. The task applies only the bootstrap Operator,
ProxyGroup, Argo manager RBAC, and its short-lived recovery mechanics.

If the task fails before the Vault Argo credential update, existing management
state is unchanged. If it fails after a new credential is written, the task
keeps the direct recovery kubeconfig until the administrator verifies Argo can
reach NMG; rollback restores the previous Vault object from a redacted local
backup in the job's protected temporary directory, then deletes the new
bootstrap resources only when no workload uses their endpoint.

## Validation gates

The NMG task is successful only when all checks pass:

1. Helm reports the `tailscale-operator` deployment Ready.
2. `ProxyGroup/nmg-operator` reports `ProxyGroupReady=True` and exposes the
   expected `nmg-operator.tailc0244b.ts.net` HTTPS URL.
3. The management cluster can call the new NMG API endpoint using the refreshed
   Argo cluster Secret.
4. `cinder-csi-nmg` reconciles to the new cluster and the existing
   `cinder-lvm` StorageClass remains non-default.
5. The NMG application set completes without a failed or `Unknown` health
   status. Applications that depend on separately unavailable external systems
   are reported explicitly and do not cause silent success.
6. Vault audit logs identify the NMG AppRole and the Semaphore task execution;
   no output contains a secret pattern.

## Alternatives considered

1. **Manual Tailscale login on every rebuilt master.** Quick for NMG, but it
   does not renew the Argo credential or provide a repeatable team workflow.
2. **Change every Argo Application destination to Nova FIPs.** Avoids the
   bootstrap step, but discards the private tailnet control plane and creates
   public-network dependency across every team.
3. **One shared OAuth key mounted into the whole Semaphore container.** Easier
   to implement, but any task with container access could use it to administer
   every team tailnet device. This design rejects that approach.

## Rollout order

NMG is the only pilot. After a successful NMG run and a review of Vault audit
events, template output, and Argo health, create equivalent per-team Vault
paths, AppRoles, Semaphore environments, and templates for GGG, KHB, LJW, and
OJE. The team identifier is data in a checked-in manifest, not an arbitrary
free-text survey input.
