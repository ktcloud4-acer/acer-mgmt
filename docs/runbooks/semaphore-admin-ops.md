# Semaphore DNS Smoke Runbook

Semaphore currently owns one low-risk `acer-mgmt` task: DNS smoke verification.
Host administration tasks such as Compose status, Docker restart, and Argo CD
smoke checks should be added later through a runner or SSH-based execution
model instead of by baking host tooling into the Semaphore server container.

## Project

Use the `acer-mgmt` Semaphore project with the `acer-mgmt` repository on the
`main` branch.

## Bash Template

Create one Bash task template:

| Template | Script filename | CLI args |
|---|---|---|
| `check:dns` | `compose/scripts/dns-smoke-test.sh` | none |

The script checks:

- AdGuard service rewrites for `grafana`, `harbor`, and `argocd`.
- Upstream recursion for `registry-1.docker.io` when `dig` or `nslookup` is
  available.
- The Semaphore container OS resolver.
- The k3d pod resolver when `kubectl` and the kubeconfig are available.

## Local Verification

Before wiring the template in Semaphore, verify the script locally:

```bash
bash compose/tests/test-dns-smoke-test.sh
compose/scripts/dns-smoke-test.sh
```

## Notes

- Keep operational logic in Git. Semaphore should only select and run reviewed
  repository scripts.
- Do not grant Docker socket access to the Semaphore server container for this
  DNS smoke task.
- Add future host-level admin tasks through Semaphore runners or explicit SSH
  inventory so the execution location is obvious.
