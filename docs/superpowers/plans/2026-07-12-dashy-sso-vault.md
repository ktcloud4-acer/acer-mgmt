# Dashy SSO and Vault Embed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Dashy Workspace authenticate browser UIs through oauth2-proxy,
including Vault, while retaining protected API and Teleport paths.

**Architecture:** Traefik routes browser UI requests through `sso-auth` and
preserves API paths that need their native credentials. Grafana consumes the
oauth2-proxy identity header through Auth Proxy; applications without an
equivalent integration retain their native session. Keycloak response headers
permit Dashy as the single iframe parent in demo mode. A Vault script
reconciles only explicitly named Dashy embed resources.

**Tech Stack:** Docker Compose, Traefik file/Docker providers, oauth2-proxy,
Keycloak, Vault CLI, Bash.

## Global Constraints

- Never print Vault token or secret values.
- Do not apply oauth2-proxy to Teleport, Vault `/v1/*`, MinIO S3, or Supabase APIs.
- Preserve Dashy's global `newtab` default.

### Task 1: Lock the route contract with tests

**Files:**
- Create: `compose/tests/test-dashy-sso-vault.sh`
- Modify: `compose/tests/test-dashy-service-index.sh`

- [ ] Add assertions for the Vault UI/API split, Keycloak Dashy framing policy,
  and explicit Workspace targets.
- [ ] Run the two Dashy test scripts and confirm they fail before the config change.

### Task 2: Reconcile Traefik, Vault, and Dashy configuration

**Files:**
- Modify: `compose/stacks/edge/traefik/config/dynamic/middlewares.yaml`
- Modify: `compose/stacks/security/vault/compose.yaml`
- Modify: `compose/stacks/edge/dashy/config/conf.yml`

- [ ] Add an iframe-safe Keycloak demo response policy for Dashy only.
- [ ] Restore explicit `vault` UI and high-priority `vault-api` routers.
- [ ] Set Workspace targets only for Grafana, Alertmanager, Semaphore, and Vault.

### Task 3: Reconcile Vault-owned embed resources

**Files:**
- Create: `compose/scripts/reconcile-vault-dashy-embed.sh`
- Modify: `docs/runbooks/dashy-service-index.md`

- [ ] Write a Vault UI-header reconciliation script that reads `/tmp/.vt`
  inside the Vault container, extends only the existing `admin` policy with
  the required endpoint, and never echoes the token.
- [ ] Limit deletion to the explicit legacy `dashy-embed-ui-headers` policy.
- [ ] Document the runtime command and verification.

### Task 4: Validate and deploy

- [ ] Run static tests and Compose rendering.
- [ ] Apply the Vault reconciliation and restart only affected stacks.
- [ ] Verify Keycloak and Vault headers, Vault API bypass, and Dashy targets.
- [ ] Commit, open a GitLab merge request, merge it into `main`, and fast-forward the server checkout.
