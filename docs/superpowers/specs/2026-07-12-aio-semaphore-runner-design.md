# AIO Semaphore Runner Design

## Goal

Register a persistent Semaphore Runner on `acer-aio` so the NMG Tailscale
Operator bootstrap task executes inside the AIO network without registering
the AIO host on Tailscale or opening mgmt-to-AIO SSH access.

## Selected Architecture

`acer-aio` runs a Dockerized Semaphore Runner.  The Runner opens outbound TLS
connections to `https://semaphore.imcherry5778.xyz`, receives its task and
returns logs to the central Semaphore server.  Bootstrap scripts running in
the Runner use `https://vault.imcherry5778.xyz` with their existing one-time
AppRole credentials, then access the NMG Kubernetes API directly at the
address contained in the recovery kubeconfig.

The AIO Runner is dedicated to the `acer-aio-nmg` project.  Central services
remain on mgmt; neither the Runner nor the AIO host receives a long-lived
Vault token, Tailscale auth key, or private SSH key.

## Components

### Central Semaphore and Vault

- Enable Semaphore remote-runner mode with
  `SEMAPHORE_USE_REMOTE_RUNNER=true`.
- Generate a random registration token at
  `kv/mgmt/cicd/semaphore-runner/aio`.  Vault Agent renders it only to the
  Semaphore service environment file.
- Keep the NMG task's one-time AppRole credentials at
  `kv/mgmt/tailscale/task-credentials/nmg`; they remain task-scoped Semaphore
  environment values.

### AIO Runner

- Run the same pinned Semaphore image version as mgmt, extended with `helm`,
  `kubectl`, `jq`, `curl`, `git`, and CA certificates.
- Persist only the Runner-issued token/configuration and workspace in an AIO
  local Docker volume or root-owned directory.
- During initial enrollment, transfer the registration token over the existing
  administrator SSH path, register once, then remove the temporary token file.
- The Runner connects to Semaphore using its issued Runner token thereafter;
  the registration token is not retained on AIO.

### NMG Bootstrap Template

- Retain `git_branch: main` and make `main` the only executable source.
- Replace the internal Docker-only Vault address with the TLS-verified public
  Vault API hostname.
- Remove the AIO SSH private-key mount, SSH tunnel lifecycle, and loopback
  kubeconfig rewrite.
- Use the recovery kubeconfig's direct Kubernetes API endpoint and CA data.

## Network and Security Boundaries

| Flow | Direction | Authentication |
| --- | --- | --- |
| Runner to Semaphore | AIO to mgmt HTTPS | Runner-issued token |
| Bootstrap task to Vault | AIO to mgmt HTTPS | One-time, least-privilege AppRole |
| Bootstrap task to Kubernetes | AIO local network | Recovery kubeconfig / Kubernetes CA |

TLS validation is required for both public mgmt endpoints.  Live checks from
AIO returned a TLS-verified `401` from Semaphore's protected API and `200`
from Vault health, proving the required outbound paths exist.

## Success Criteria

1. The Runner is online and registered in the `acer-aio-nmg` Semaphore project.
2. The Runner can receive an NMG task over HTTPS and report its log to mgmt.
3. The bootstrap task accesses Vault and the NMG Kubernetes API without
   `/run/secrets/acer.pem`, `172.16.1.10`, or an SSH tunnel.
4. No long-lived Vault token, Tailscale key, SSH private key, or registration
   token remains in Git, a task log, or the persistent AIO Runner configuration.
