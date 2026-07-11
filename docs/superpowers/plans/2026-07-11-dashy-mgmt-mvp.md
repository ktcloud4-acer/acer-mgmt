# Dashy Management MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a Keycloak-protected Dashy MVP alongside Homepage with the service index, Status page, and a narrow Grafana Workspace embed.

**Architecture:** Dashy is a read-only navigation shell behind Traefik and the existing OAuth2 Proxy. Prometheus, Blackbox, node-exporter, and Grafana remain the monitoring system of record. Only Grafana's `d-solo/mgmt-operations-overview` route may be framed by Dashy.

**Tech Stack:** Docker Compose, Dashy 4.1.5, Traefik 3.5, Keycloak/OAuth2 Proxy, Grafana 13, YAML, JSON, Bash.

## Global Constraints

- Preserve `home.${BASE_DOMAIN}` and its files unchanged.
- Pin `ghcr.io/lissy93/dashy:4.1.5`; do not use `latest`.
- Use existing `sso-auth@file,secure-headers@file` on the Dashy router.
- Mount `/app/user-data` read-only; never mount Docker socket, kubeconfig, Vault, or service credentials.
- Set `disableConfiguration`, `preventWriteToDisk`, and `preventLocalSave` to `true`.
- Set `statusCheckInterval: 0`; no Dashy API or Prometheus widgets.
- Keep privileged apps new-tab-only and hidden from Workspace.
- Restrict Grafana framing to `https://dash.${BASE_DOMAIN}` and `/d-solo/mgmt-operations-overview`.

## File Structure

| File | Responsibility |
|---|---|
| `compose/stacks/edge/dashy/compose.yaml` | Dashy container, route, SSO, and read-only mount. |
| `compose/stacks/edge/dashy/config/conf.yml` | Home index, safety settings, Status registration, Workspace policy. |
| `compose/stacks/edge/dashy/config/status.yml` | Eight bounded page-load availability cards. |
| `compose/stacks/observability/grafana/compose.yaml` | Grafana's dedicated embed router and CSP. |
| `compose/stacks/observability/grafana/dashboards/Monitoring/mgmt_operations_overview.json` | Four-panel Grafana overview. |
| `compose/tests/test-dashy-mvp.sh` | Static regression contract. |
| `docs/runbooks/dashy-mgmt-mvp.md` | Deployment and rollback procedure. |

## Task 1: Define the failing configuration contract

**Files:** Create `compose/tests/test-dashy-mvp.sh`.

**Interfaces:** It consumes the later Dashy and Grafana files and produces the executable gate `bash compose/tests/test-dashy-mvp.sh`.

- [ ] Write an executable Bash test with `set -euo pipefail`, an `assert_file` helper, and an `assert_contains` helper. Assert the Dashy image, config mount, Dashy host rule, `sso-auth@file,secure-headers@file`, `disableConfiguration: true`, `preventWriteToDisk: true`, `preventLocalSave: true`, `statusCheckInterval: 0`, the `Status` page, all seven Home groups, Status titles `Dashy`, `Grafana`, `Prometheus`, `Alertmanager`, `Argo CD`, `GitLab`, `NetBox`, `Vault`, and the Grafana dashboard UID `mgmt-operations-overview`.
- [ ] Add the exact Grafana security assertions: `GF_SECURITY_ALLOW_EMBEDDING: "true"`; router rule `Host(` + "`grafana.${BASE_DOMAIN}`" + `) && PathPrefix(` + "`/d-solo/mgmt-operations-overview`" + `)`; middleware `grafana-embed-headers@docker`; CSP string `Content-Security-Policy=frame-ancestors https://dash.${BASE_DOMAIN}`.
- [ ] Run `bash compose/tests/test-dashy-mvp.sh`; expect a missing Dashy Compose file failure.
- [ ] Commit with `git add compose/tests/test-dashy-mvp.sh && git commit -m "test: define Dashy MVP contract"`.

## Task 2: Implement the isolated Dashy shell

**Files:** Create `compose/stacks/edge/dashy/compose.yaml`, `compose/stacks/edge/dashy/config/conf.yml`, and `compose/stacks/edge/dashy/config/status.yml`; test `compose/tests/test-dashy-mvp.sh`.

**Interfaces:** The service consumes `${BASE_DOMAIN}`, `${TZ}`, `${PROXY_NET:-mgmt-proxy}`, `sso-auth@file`, and `secure-headers@file`; it produces container `dashy` on `dash.${BASE_DOMAIN}`.

- [ ] Create the Compose service with `image: ghcr.io/lissy93/dashy:4.1.5`, `container_name: dashy`, `restart: unless-stopped`, `user: "1000:1000"`, `security_opt: [no-new-privileges:true]`, `cap_drop: [ALL]`, `TZ: ${TZ:-Asia/Seoul}`, `DASHY_VAR_BASE_DOMAIN: ${BASE_DOMAIN}`, `./config:/app/user-data:ro,Z`, and the existing external `mgmt-proxy` network.
- [ ] Add Dashy labels exactly: `traefik.enable=true`; `traefik.docker.network=${PROXY_NET:-mgmt-proxy}`; `traefik.http.routers.dashy.rule=Host(` + "`dash.${BASE_DOMAIN}`" + `)`; `traefik.http.routers.dashy.entrypoints=websecure`; `traefik.http.routers.dashy.middlewares=sso-auth@file,secure-headers@file`; `traefik.http.services.dashy.loadbalancer.server.port=8080`.
- [ ] Configure `conf.yml` with title `ACER Operations`, Home start view, `defaultOpeningMethod: newtab`, `statusCheck: false`, `statusCheckInterval: 0`, all three configuration-write protections, and `pages: [{ name: Status, path: status.yml }]`.
- [ ] Recreate all current Homepage groups without changing their URLs: Observability (Grafana, Prometheus, Alertmanager, Kibana, n8n); Backup (MinIO, Restic); CI/CD (Argo CD, GitLab, GitLab Runner, SonarQube, Allure, Playwright, Semaphore, Harbor); Data (Kafka, Supabase); Infra (NetBox); Security (Keycloak, Teleport, Vault); Edge (Traefik, AdGuard Home). Use `https://<service>.{{DASHY_VAR_BASE_DOMAIN}}` for each existing endpoint and preserve special Allure, Playwright, and Teleport URL suffixes from Homepage.
- [ ] Add one workspace-visible item titled `Grafana Operations Summary` at `https://grafana.{{DASHY_VAR_BASE_DOMAIN}}/d-solo/mgmt-operations-overview?orgId=1&panelId=1` with `target: workspace`; set every other URL card to `target: newtab` and `displayData.hideFromWorkspace: true`.
- [ ] Create `status.yml` with one `Control Plane Status` section. Its eight cards are Dashy, Grafana, Prometheus, Alertmanager, Argo CD, GitLab, NetBox, and Vault; every card has `statusCheck: true`, `target: newtab`, `displayData.hideFromWorkspace: true`, and the same URL as Home.
- [ ] Run `bash compose/tests/test-dashy-mvp.sh`; expect all Dashy assertions to pass and Grafana assertions to fail.
- [ ] Commit with `git add compose/stacks/edge/dashy compose/tests/test-dashy-mvp.sh && git commit -m "feat: add Dashy management shell"`.

## Task 3: Implement Grafana's read-only workspace surface

**Files:** Modify `compose/stacks/observability/grafana/compose.yaml`; create `compose/stacks/observability/grafana/dashboards/Monitoring/mgmt_operations_overview.json`; test `compose/tests/test-dashy-mvp.sh`.

**Interfaces:** The dashboard uses the existing datasource `{ "type": "prometheus", "uid": "prometheus" }`; its UID, Dashy URL, and router path are all `mgmt-operations-overview`.

- [ ] Add `GF_SECURITY_ALLOW_EMBEDDING: "true"` after `GF_SERVER_ROOT_URL`. Do not change the existing `grafana.middlewares=secure-headers@file` label.
- [ ] Add a high-priority Docker router matching Grafana host plus `PathPrefix(`/d-solo/mgmt-operations-overview`)`, with priority `100`, service `grafana`, and middleware `grafana-embed-headers@docker`.
- [ ] Define `grafana-embed-headers` by Docker labels with `contenttypenosniff=true`, `browserxssfilter=true`, `stsseconds=31536000`, `stsincludesubdomains=true`, and `customresponseheaders.Content-Security-Policy=frame-ancestors https://dash.${BASE_DOMAIN}`. Do not set `frameDeny` on this special router.
- [ ] Create dashboard UID `mgmt-operations-overview`, title `Management Operations Overview`, range `now-15m` to `now`, and four `stat` panels with `lastNotNull` reductions: `sum(up)` (`Reachable Prometheus Targets`); `sum(up == 0)` (`Unreachable Prometheus Targets`); `sum(ALERTS{alertstate="firing"})` (`Firing Alerts`); and `sum(up{job=~".*alertmanager.*"})` (`Active Alertmanager Instances`). Use green at one for panels 1/4; green zero and red one for panels 2/3.
- [ ] Run `bash compose/tests/test-dashy-mvp.sh`; expect `Dashy MVP configuration tests passed`.
- [ ] Commit with `git add compose/stacks/observability/grafana compose/tests/test-dashy-mvp.sh && git commit -m "feat: add Dashy Grafana workspace summary"`.

## Task 4: Validate and deploy on management

**Files:** Create `docs/runbooks/dashy-mgmt-mvp.md`; modify `docs/superpowers/specs/2026-07-11-dashy-mgmt-mvp-design.md` to describe `@docker`, not `@file`.

**Interfaces:** Uses the supplied SSH identity for `user1@acer-mgmt`; produces healthy `dashy` and Grafana services while preserving Homepage.

- [ ] Run `bash compose/tests/test-dashy-mvp.sh`; expect success.
- [ ] On `acer-mgmt`, render Dashy with `docker compose --env-file ../.env -f stacks/edge/dashy/compose.yaml config >/dev/null` and Grafana with the existing rendered observability Vault env file; expect both exit zero.
- [ ] Deploy Grafana before Dashy with their existing Compose commands, then inspect `docker ps --format '{{.Names}} {{.Status}}'`; expect both `grafana` and `dashy` healthy.
- [ ] Verify unauthenticated `https://dash.${BASE_DOMAIN}` redirects to the existing SSO path, `https://home.${BASE_DOMAIN}` is non-5xx, the solo Grafana response has only Dashy's `frame-ancestors` CSP, and normal Grafana retains `X-Frame-Options: DENY`.
- [ ] As `platform-admin`, verify all seven Home groups, the eight-card Status page, the Grafana Workspace summary without a framing error, Vault/Teleport top-level opening, and Homepage preservation. If Keycloak blocks iframe login, change only the summary card to `target: newtab` and `hideFromWorkspace: true`; never relax Keycloak framing or enable Grafana anonymous access.
- [ ] Write the runbook with exact deployment commands and rollback: stop only the Dashy Compose stack, revert the Dashy MVP commit, then reapply Grafana Compose. Commit with `git add docs/superpowers/specs/2026-07-11-dashy-mgmt-mvp-design.md docs/runbooks/dashy-mgmt-mvp.md && git commit -m "docs: add Dashy MVP operations runbook"`.

## Plan Self-Review

- Tasks 1–2 cover the Dashy stack, preserved index, Status page, and Workspace policy.
- Task 3 covers the only allowed iframe and preserves the normal Grafana anti-framing router.
- Task 4 covers rendering, live deployment, SSO, browser verification, Homepage preservation, and rollback.
- The UID, Dashy URL, router path, and test identifier consistently use `mgmt-operations-overview`.
