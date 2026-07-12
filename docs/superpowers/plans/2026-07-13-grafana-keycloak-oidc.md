# Grafana Keycloak OIDC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Grafana browser authentication from oauth2-proxy Auth Proxy headers to the Keycloak `mgmt` realm and synchronize `grafana-editor` to the Grafana Editor role.

**Architecture:** Grafana becomes a confidential Keycloak OIDC client. A client-specific Keycloak groups mapper places membership in the OIDC token, and Grafana's generic OAuth role expression maps `grafana-editor` to `Editor`, otherwise `Viewer`. The bootstrap writes the client secret only to Vault KV v2; Vault Agent renders it as a file consumed through Grafana's `__FILE` setting.

**Tech Stack:** Keycloak 26.5, Grafana 13.0.2, Docker Compose, Vault KV v2, Vault Agent, Bash.

## Global Constraints

- Never write a Keycloak client secret, Vault token, or Keycloak administrator password to Git, a Compose environment variable, or command output.
- Grafana's public router must use native OIDC and must not apply `sso-auth@file`.
- The `grafana-editor` group remains the authority for the Grafana Editor organization role.

---

### Task 1: Define the OIDC contract with a regression test

**Files:**
- Create: `compose/tests/test-grafana-keycloak-oidc.sh`
- Modify: `compose/tests/test-dashy-sso-vault.sh`

- [x] **Step 1: Write the failing test**

Assert Generic OAuth, the group-to-role expression, the secret-file mount, the native router, the Keycloak bootstrap contract, and the Vault Agent render contract.

- [x] **Step 2: Run test to verify it fails**

Run: `"C:/Program Files/Git/bin/bash.exe" -lc './compose/tests/test-grafana-keycloak-oidc.sh'`

Expected: `FAIL` because Grafana currently sets `GF_AUTH_GENERIC_OAUTH_ENABLED: "false"`.

### Task 2: Reconcile Keycloak and Vault client-secret state

**Files:**
- Create: `compose/scripts/keycloak-grafana-oidc-bootstrap.sh`
- Modify: `compose/stacks/security/vault-agent/config/agent.hcl`

- [ ] **Step 1: Implement the idempotent client bootstrap**

Use the Keycloak Admin CLI inside the Keycloak container to reconcile the confidential `grafana` client, its callback URL, origin, and client-scoped `groups` mapper. Use `vault-kv2-patch-secret.py` with the Vault container's `/tmp/.vt` token to write only `kv/mgmt/grafana:oidc_client_secret`.

- [ ] **Step 2: Render the secret as a dedicated file**

Add a Vault Agent template for `/vault/secrets/grafana_oidc_client_secret` with `0640` mode.

### Task 3: Make Grafana a native Keycloak OIDC client

**Files:**
- Modify: `compose/stacks/observability/grafana/compose.yaml`

- [ ] **Step 1: Replace Auth Proxy configuration with Generic OAuth**

Configure Keycloak issuer endpoints, client identifier, secret `__FILE`, `groups` claim extraction, and `grafana-editor` to `Editor` mapping. Keep the Grafana login form disabled and disable Auth Proxy.

- [ ] **Step 2: Route Grafana without oauth2-proxy**

Use only `secure-headers@file` on the Grafana router so the Authorization Code callback is never redirected by the shared browser gate.

### Task 4: Verify source and runtime preconditions

**Files:**
- Test: `compose/tests/test-grafana-keycloak-oidc.sh`
- Test: `compose/tests/test-dashy-sso-vault.sh`

- [ ] **Step 1: Run static regression tests**

Run both Bash tests with Git Bash and confirm they pass.

- [ ] **Step 2: Run Compose validation**

Render the Grafana Compose configuration with a non-secret placeholder environment and confirm that the OIDC secret remains a file mount.

- [ ] **Step 3: Reconcile runtime state when Docker becomes reachable**

Run the bootstrap on the mgmt host, restart Vault Agent to render the secret, recreate Grafana, then verify a `grafana-editor` user receives the `Editor` organization role after a fresh login.
