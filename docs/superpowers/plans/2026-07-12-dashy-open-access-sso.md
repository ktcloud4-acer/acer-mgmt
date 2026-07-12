# Dashy Open-Access SSO Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow every authenticated `mgmt` Keycloak user through the shared
browser gateway and redirect the auth-host root to Dashy without affecting
oauth2 callback or API routes.

**Architecture:** Remove only oauth2-proxy's group authorization flag. Add a
higher-priority exact-root Traefik router on `auth.<BASE_DOMAIN>` that applies
a redirect middleware to Dashy, while the existing host-wide router continues
to serve `/oauth2/*` callbacks. Native API routers remain unchanged.

**Tech Stack:** Docker Compose, Traefik Docker/file providers, oauth2-proxy,
Bash static contract tests.

## Global Constraints

- Keep Keycloak authentication, cookie security, and the existing oauth2
  callback URL unchanged.
- Do not add SSO to Vault `/v1/*`, MinIO S3, Supabase APIs, or Teleport.
- Do not remove application-native authorization.
- Keep the auth-root redirect temporary (`302`) so the destination can be
  changed without browser cache invalidation.

### Task 1: Lock the open-access and callback contracts with tests

**Files:**
- Modify: `compose/tests/test-oauth2-proxy-stack.sh`

- [ ] **Step 1: Write the failing assertions**

Add assertions that the oauth2-proxy Compose file contains no
`--allowed-group=`, declares `oauth2-root` with exact rule
`Host(\`auth.${BASE_DOMAIN}\`) && Path(\`/\`)`, priority `100`, and the
`auth-root-redirect@file` middleware. Add an assertion that the dynamic
middleware redirects `https://auth.<BASE_DOMAIN>/` to
`https://dash.<BASE_DOMAIN>/`.

- [ ] **Step 2: Run the focused test and verify failure**

Run: `bash compose/tests/test-oauth2-proxy-stack.sh`

Expected: failure because the group flag is still present and the exact-root
router/redirect do not exist.

- [ ] **Step 3: Add the minimal configuration**

Remove the oauth2-proxy command line `--allowed-group` entry. In
`middlewares.yaml`, add:

```yaml
auth-root-redirect:
  redirectRegex:
    regex: "^https://auth\\.imcherry5778\\.xyz/?$"
    replacement: "https://dash.imcherry5778.xyz/"
    permanent: false
```

In oauth2-proxy labels, add a higher-priority `oauth2-root` router with exact
root rule, the redirect middleware, and the existing oauth2-proxy service.

- [ ] **Step 4: Run focused tests and Compose rendering**

Run:

```bash
bash compose/tests/test-oauth2-proxy-stack.sh
BASE_DOMAIN=example.invalid docker compose \
  -f compose/stacks/security/oauth2-proxy/compose.yaml config --quiet
```

Expected: both commands exit `0`.

- [ ] **Step 5: Commit**

```bash
git add compose/stacks/security/oauth2-proxy/compose.yaml \
  compose/stacks/edge/traefik/config/dynamic/middlewares.yaml \
  compose/tests/test-oauth2-proxy-stack.sh
git commit -m "feat: simplify shared SSO access"
```

### Task 2: Document and verify the browser flow

**Files:**
- Modify: `compose/stacks/security/oauth2-proxy/README.md`
- Modify: `docs/runbooks/dashy-service-index.md`

- [ ] **Step 1: Add the expected-flow documentation**

Document that all authenticated `mgmt` Keycloak users pass the shared gateway,
`auth` root redirects to Dashy, and `/oauth2/*` remains callback-only. State
that native API/service authorization is unchanged.

- [ ] **Step 2: Run all relevant static tests**

Run:

```bash
bash compose/tests/test-oauth2-proxy-stack.sh
bash compose/tests/test-dashy-sso-vault.sh
bash compose/tests/test-dashy-service-index.sh
git diff --check
```

Expected: all exit `0`.

- [ ] **Step 3: Commit**

```bash
git add compose/stacks/security/oauth2-proxy/README.md \
  docs/runbooks/dashy-service-index.md
git commit -m "docs: describe simplified Dashy SSO"
```

### Task 3: Deploy and verify live routing

**Files:** none

- [ ] **Step 1: Update the server and recreate oauth2-proxy**

Run on `acer-mgmt` from `/home/user1/acer-mgmt/compose`:

```bash
docker compose --env-file ../.env \
  -f stacks/security/oauth2-proxy/compose.yaml up -d
```

- [ ] **Step 2: Verify the public routing contract**

Run:

```bash
curl -ksS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://auth.imcherry5778.xyz/
curl -ksS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://auth.imcherry5778.xyz/oauth2/start
curl -ksS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://vault.imcherry5778.xyz/
curl -ksS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://vault.imcherry5778.xyz/v1/sys/health
```

Expected: auth root redirects to Dashy; callback/start remains oauth2-proxy;
Vault UI enters Keycloak SSO when unauthenticated; Vault API has no Keycloak
redirect.

- [ ] **Step 3: Push, open MR, merge, and synchronize**

Push the feature branch, create a GitLab merge request, fast-forward `main`,
then fast-forward both the local checkout and `/home/user1/acer-mgmt` to the
same final commit. Record the commit and runtime verification output.
