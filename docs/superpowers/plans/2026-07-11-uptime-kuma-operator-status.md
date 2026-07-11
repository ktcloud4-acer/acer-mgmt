# Uptime Kuma Operator Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy an SSO-protected Uptime Kuma board on `acer-mgmt` and document monitoring for `nmg`, `ggg`, `oje`, `khb`, and `ljw`.

**Architecture:** One Compose service joins the existing `mgmt-proxy` network and persists to the local `DATA_ROOT`. It checks management health paths, each team's Tailscale Kubernetes API `/livez`, and each team's public ScaleCart dashboard. Prometheus remains responsible for node, kubelet, pod, and object state.

**Tech Stack:** Docker Compose, Traefik labels, oauth2-proxy forward auth, Uptime Kuma 2.x, Homepage YAML, Bash contract tests.

## Global Constraints

- Use `louislam/uptime-kuma:2` and a local `${DATA_ROOT:-/home/mgmt-data}/uptime-kuma` data path.
- Do not add host ports, Docker socket mounts, `acer-aio` changes, or Kubernetes manifests.
- Protect the UI with `sso-auth@file,secure-headers@file`.
- Keep Kuma notifications disabled for the existing Blackbox endpoints.
- Do not seed SQLite or use Uptime Kuma's unsupported internal Socket.IO API; create the monitors in the authenticated UI from the checked-in runbook.

---

### Task 1: Add a failing service contract and the Compose stack

**Files:**
- Create: `compose/tests/test-uptime-kuma-stack.sh`
- Create: `compose/stacks/observability/uptime-kuma/compose.yaml`

**Interfaces:**
- Consumes: `BASE_DOMAIN`, `DATA_ROOT`, `PROXY_NET`, and `TZ` from the normal Compose environment.
- Produces: service `uptime-kuma` and SSO-protected host `kuma.${BASE_DOMAIN}`.

- [ ] **Step 1: Write the failing test**

Create `compose/tests/test-uptime-kuma-stack.sh` using the existing shell-test assertion pattern. It must require these strings in the new Compose file:

```bash
assert_contains "$compose_file" "image: louislam/uptime-kuma:2"
assert_contains "$compose_file" "container_name: uptime-kuma"
assert_contains "$compose_file" "restart: unless-stopped"
assert_contains "$compose_file" '${DATA_ROOT:-/home/mgmt-data}/uptime-kuma:/app/data:Z'
assert_contains "$compose_file" "traefik.http.routers.uptime-kuma.rule=Host(`kuma.${BASE_DOMAIN}`)"
assert_contains "$compose_file" "traefik.http.routers.uptime-kuma.middlewares=sso-auth@file,secure-headers@file"
assert_contains "$compose_file" "traefik.http.services.uptime-kuma.loadbalancer.server.port=3001"
assert_contains "$compose_file" "test: [\"CMD\", \"extra/healthcheck\"]"
assert_not_contains "$compose_file" "/var/run/docker.sock"
assert_not_contains "$compose_file" "ports:"
```

- [ ] **Step 2: Verify the test fails**

Run `bash compose/tests/test-uptime-kuma-stack.sh`.

Expected: it fails because the Compose file does not exist.

- [ ] **Step 3: Implement the smallest passing service**

Create `compose/stacks/observability/uptime-kuma/compose.yaml`:

```yaml
services:
  uptime-kuma:
    image: louislam/uptime-kuma:2
    container_name: uptime-kuma
    restart: unless-stopped
    environment:
      TZ: ${TZ:-Asia/Seoul}
    volumes:
      - ${DATA_ROOT:-/home/mgmt-data}/uptime-kuma:/app/data:Z
    networks:
      - default
      - mgmt-proxy
    healthcheck:
      test: ["CMD", "extra/healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=${PROXY_NET:-mgmt-proxy}"
      - "traefik.http.routers.uptime-kuma.rule=Host(`kuma.${BASE_DOMAIN}`)"
      - "traefik.http.routers.uptime-kuma.entrypoints=websecure"
      - "traefik.http.routers.uptime-kuma.middlewares=sso-auth@file,secure-headers@file"
      - "traefik.http.services.uptime-kuma.loadbalancer.server.port=3001"

networks:
  mgmt-proxy:
    name: ${PROXY_NET:-mgmt-proxy}
    external: true
```

- [ ] **Step 4: Verify the implementation**

Run:

```bash
bash compose/tests/test-uptime-kuma-stack.sh
docker compose --env-file .env -f compose/stacks/observability/uptime-kuma/compose.yaml config >/dev/null
```

Expected: both commands exit zero.

### Task 2: Make every team cluster part of the checked-in monitor inventory

**Files:**
- Modify: `compose/tests/test-uptime-kuma-stack.sh`
- Modify: `compose/stacks/edge/homepage/config/services.yaml`
- Create: `docs/runbooks/uptime-kuma-2026-07-11.md`

**Interfaces:**
- Consumes: the private Kuma route and five team identifiers.
- Produces: Homepage navigation and an exact 13-monitor operator inventory.

- [ ] **Step 1: Extend the failing test**

Require a Homepage entry and the monitor URLs in the runbook:

```bash
assert_contains "$homepage_services" "Uptime Kuma:"
assert_contains "$homepage_services" "https://kuma.{{HOMEPAGE_VAR_BASE_DOMAIN}}"
for team in nmg ggg oje khb ljw; do
  assert_contains "$runbook" "https://${team}-operator.tailc0244b.ts.net/livez"
  assert_contains "$runbook" "https://${team}.\${BASE_DOMAIN}/"
done
```

- [ ] **Step 2: Verify the extended test fails**

Run `bash compose/tests/test-uptime-kuma-stack.sh`.

Expected: it fails because neither the Homepage item nor runbook exists.

- [ ] **Step 3: Add the operator-facing documentation**

Add this entry to the `Observability` group in `services.yaml`:

```yaml
    - Uptime Kuma:
        icon: uptime-kuma.png
        href: https://kuma.{{HOMEPAGE_VAR_BASE_DOMAIN}}
        description: Private outside-in service and team-cluster status board
```

Create the runbook. It must list the three management monitors at 60 seconds
with notifications disabled, plus for every `nmg`, `ggg`, `oje`, `khb`, and
`ljw`:

```text
<TEAM> Kubernetes API /livez  https://<team>-operator.tailc0244b.ts.net/livez  HTTP 200  60s
<TEAM> ScaleCart dashboard    https://<team>.${BASE_DOMAIN}/                   HTTP 200  60s
```

The runbook must state that `oje`, `khb`, and `ljw` may initially display down
because their API proxies timed out and public dashboards returned 530 during
pre-deployment verification. It must direct the operator to create monitors in
the supported authenticated UI, not by changing SQLite or calling an
unsupported internal API.

- [ ] **Step 4: Verify the inventory**

Run `bash compose/tests/test-uptime-kuma-stack.sh && git diff --check`.

Expected: both commands exit zero.

### Task 3: Deploy and validate the supported central runtime

**Files:**
- Uses: Task 1 and Task 2 files only.

**Interfaces:**
- Consumes: merged `main`, the live `mgmt-proxy`, Traefik, oauth2-proxy, and Restic configuration.
- Produces: one healthy Kuma container, private SSO UI, and 13 runtime monitors.

- [ ] **Step 1: Run the complete static suite**

Run all `compose/tests/test-*.sh` scripts. Record the already diagnosed
external-worktree-only `test-sre-bp-artifacts.sh` path failure separately; the
Kuma focused test must pass.

- [ ] **Step 2: Synchronize the merged commit and start Kuma**

On `acer-mgmt`, prove the deployment checkout is on the merged `main` commit,
then run:

```bash
docker compose --env-file .env -f compose/stacks/observability/uptime-kuma/compose.yaml config >/dev/null
docker compose --env-file .env -f compose/stacks/observability/uptime-kuma/compose.yaml up -d
```

- [ ] **Step 3: Verify service and SSO boundary**

Run:

```bash
sudo docker ps --filter name=^/uptime-kuma$ --format '{{.Status}}'
sudo docker inspect uptime-kuma --format '{{.State.Health.Status}}'
curl -k -I --connect-timeout 12 https://kuma.${BASE_DOMAIN}/
```

Expected: a running, healthy container and an existing SSO response; no direct
host port is exposed.

- [ ] **Step 4: Create and compare the 13 monitors**

Use the SSO-protected UI to create the local Kuma administrator and the exact
13 monitors in the runbook. Leave Kuma notification providers disabled. From
`acer-mgmt`, compare each Kuma outcome to a `curl -k --connect-timeout 12`
request. Management, `nmg`, and `ggg` should currently be up; `oje`, `khb`,
and `ljw` remain down until their upstream routes recover.

- [ ] **Step 5: Verify persistence and recovery**

Confirm `/home/mgmt-data/uptime-kuma` has the SELinux container label and is
inside Restic's existing `${DATA_ROOT}` source tree. Stop then start only the
Kuma Compose stack and verify monitor definitions persist. Do not remove the
data directory.

### Task 4: Complete the approved Git Y flow

**Files:**
- Commit: all scoped Kuma stack, test, Homepage, runbook, design, and plan files.

**Interfaces:**
- Consumes: passing focused tests and Task 3 runtime evidence.
- Produces: merged/synchronized `main` and cleaned feature branch.

- [ ] **Step 1: Commit**

Run `git add` only scoped files, then commit:

```bash
git commit -m "feat(observability): add operator uptime kuma board"
```

- [ ] **Step 2: Push and open the GitLab merge request**

Push `feat/uptime-kuma`, create an MR to `main`, and include focused test and
runtime evidence. State explicitly that no Kubernetes, Nova VM, or `acer-aio`
workload was added.

- [ ] **Step 3: Merge and synchronize**

Merge into `main`; synchronize local `main`, remote `main`, and the live
`acer-mgmt` checkout to the same commit. Delete the merged feature branch
locally and remotely.

- [ ] **Step 4: Report final evidence**

Report local/remote/live commit IDs, `git status`, Kuma health, SSO route,
the 13 monitor outcomes, existing Blackbox health, and the distinction between
currently reachable and offline team clusters.
