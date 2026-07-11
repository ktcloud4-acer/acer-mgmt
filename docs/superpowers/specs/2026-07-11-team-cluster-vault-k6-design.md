# Team Cluster Vault and k6 Control Plane Design

## Decision

The management k3d cluster remains the only Argo CD and Semaphore control
plane. The five team Kubernetes API servers (`ggg`, `khb`, `ljw`, `nmg`, and
`oje`) are registered once in Argo CD and are never accessed by a browser user
token or a Semaphore-issued token.

Each target cluster owns a dedicated machine identity for Argo CD. The Argo CD
cluster connection data (`name`, `server`, and `config` containing its bearer
token and TLS data) is stored in Vault at
`kv/mgmt/argocd/clusters/<cluster>`. The management cluster External Secrets
Operator renders those Vault entries as Argo CD cluster Secrets in the
`argocd` namespace. Vault is therefore the source of truth; Git contains only
the ExternalSecret manifests and never connection credentials.

## Scope

- Register and reconcile all five existing Argo CD cluster connections through
  Vault-backed Secrets.
- Add management-cluster External Secrets Operator and a least-privilege Vault
  Kubernetes-auth role that can read only `kv/mgmt/argocd/clusters/*`.
- Move the Semaphore Compose stack off root `.env` secret expansion and onto
  the existing Vault Agent rendered `cicd/semaphore.env` file.
- Add one standardized k6 API HPA task per existing Semaphore team project:
  `acer-aio-ggg`, `acer-aio-khb`, `acer-aio-ljw`, `acer-aio-nmg`, and
  `acer-aio-oje`.
- Keep `acer-mgmt` as the control-plane project; it owns the provisioning and
  reconciliation task, not team load tests.
- Move the Chaos Dashboard token-issuer kubeconfig from a Semaphore-only
  encrypted variable to a Vault path. It remains a single mgmt-cluster
  credential and issues only the existing ten-minute central Dashboard token.

## Explicit Non-Goals

- Do not install Semaphore or k6 in each team cluster.
- Do not expose a target cluster token in a dashboard, Git, `.env`, task log,
  or Semaphore project variable.
- Do not create Chaos Mesh `RemoteCluster` resources as part of this change.
  Their ownership conflicts with the current Argo CD-managed Chaos Mesh Helm
  releases and requires a separate migration.
- Do not move non-secret settings such as `BASE_DOMAIN`, `TZ`, volume paths,
  or network names into Vault. “No `.env` secrets” means `.env` becomes
  non-secret configuration only.

## Argo CD Credential Flow

1. A one-time import script copies the already-working Argo CD connection
   Secrets into Vault without printing token or CA data.
2. A Vault bootstrap script configures `kubernetes-mgmt` auth, a policy limited
   to `kv/data/mgmt/argocd/clusters/*`, and a role bound to the management ESO
   controller ServiceAccount.
3. The management ESO `ClusterSecretStore` authenticates to Vault using that
   Kubernetes ServiceAccount.
4. Five `ExternalSecret` resources write the required `name`, `server`, and
   `config` keys into `argocd` namespace Secrets labelled
   `argocd.argoproj.io/secret-type: cluster`.
5. Existing Application destination URLs continue to resolve through the same
   five Argo CD cluster names; no workload Application needs a credential in
   Git.

## Semaphore and k6 Flow

1. Vault Agent renders the Semaphore database/admin/encryption fields to
   `/home/mgmt-data/vault-agent/secrets/cicd/semaphore.env`.
2. Compose reads that rendered file via `env_file`; root `.env` cannot supply
   a Semaphore secret.
3. A Git-tracked task manifest maps each Semaphore project to its public API
   base URL and Vault secret path. The manifest does not hold any token.
4. At task start, the runner reads its team’s Vault Agent-rendered `K6_DEMO_API_KEY`
   file and invokes the same checked-in k6 script. This key is accepted only by
   the read-only `GET /api/demo/state` endpoint; normal API routes still require
   a Supabase JWT. The task can override non-secret rate and duration only.
5. The load originates from the mgmt Semaphore runner, while the selected
   team’s API HPA reacts inside the selected target cluster.

## Chaos Dashboard Flow

The central Dashboard login uses one ten-minute token issued for the mgmt
cluster `chaos-dashboard-manager` ServiceAccount. This is independent of the
five Argo CD cluster credentials. Vault stores the narrowly-scoped issuer
kubeconfig; the runner is authorized only to request that one service-account
token and cannot read target resources or mint target-cluster credentials.

## Safety and Validation

- All import/reconcile scripts use `umask 077`, temporary files, and trap-based
  removal. They must not echo Secret content.
- A static test asserts all five cluster definitions, Vault paths, ESO targets,
  and no secret expansion from root `.env` in Semaphore Compose.
- Runtime checks verify the five Argo CD cluster Secrets, five project/task
  bindings, Vault render files, and that no tokens appear in Git status or task
  output.
- Team k6 tasks run serially per cluster to prevent overlapping demo load.

## Acceptance Criteria

1. `argocd` in mgmt lists `ggg`, `khb`, `ljw`, `nmg`, and `oje` as registered
   and reachable clusters backed by Vault-rendered Secrets.
2. Vault contains five Argo cluster resources and the central Chaos issuer
   resource; their values are not printed or committed.
3. Semaphore Compose starts using only the Vault-rendered secret env file.
4. Each `acer-aio-*` project contains one `ScaleCart API HPA Load Test` task
   with the correct target URL and isolated secret scope.
5. Existing Argo Applications remain Synced/Healthy and the current NMG API
   HPA remains active after reconciliation.
