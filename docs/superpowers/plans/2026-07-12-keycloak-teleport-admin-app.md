# Keycloak Teleport Admin App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Register a supplemental Keycloak admin console in Teleport without changing the platform's canonical OIDC issuer.

**Architecture:** Add one static `app_service.apps` item pointing at the private Keycloak service and an exact Teleport app DNS rewrite. The app rewrites only canonical Keycloak redirects; it does not change Keycloak or oauth2-proxy settings.

**Tech Stack:** Teleport 18 static app configuration, AdGuard Home DNS rewrite script, Bash tests.

### Task 1: Lock the Keycloak admin app contract with a failing test

**Files:**
- Modify: `compose/tests/test-privileged-teleport-routes.sh`
- Modify: `compose/stacks/security/teleport/config/teleport.yaml`
- Modify: `compose/scripts/configure-teleport-app-dns.sh`

- [ ] Add assertions for `name: keycloak-admin`, `uri: http://keycloak:8080`, `public_addr: keycloak-admin.teleport.imcherry5778.xyz`, canonical redirect rewrite, security labels, and the DNS app list.
- [ ] Run `bash compose/tests/test-privileged-teleport-routes.sh`; expect failure before configuration changes.
- [ ] Add the static Teleport App definition and the exact DNS rewrite name.
- [ ] Re-run the test; expect `privileged Teleport route tests passed`.

### Task 2: Validate and deploy the isolated access path

**Files:**
- No source changes.

- [ ] Render `compose/stacks/security/teleport/compose.yaml` with the server environment.
- [ ] Run the AdGuard rewrite reconciliation as root on `acer-mgmt`.
- [ ] Recreate only the `teleport` container.
- [ ] Verify `https://keycloak-admin.teleport.imcherry5778.xyz:3080` reaches the Teleport proxy and `https://keycloak.imcherry5778.xyz` remains available.

### Task 3: Publish

**Files:**
- Create: `docs/superpowers/specs/2026-07-12-keycloak-teleport-admin-app-design.md`
- Create: `docs/superpowers/plans/2026-07-12-keycloak-teleport-admin-app.md`

- [ ] Run the focused static test and `git diff --check`.
- [ ] Commit the app configuration, DNS contract, tests, design, and plan.
- [ ] Push `main`, merge it into the management-host checkout, and re-run live verification.
