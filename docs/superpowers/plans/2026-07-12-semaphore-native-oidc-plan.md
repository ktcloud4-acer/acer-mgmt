# Semaphore Native OIDC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate Semaphore's Dashy iframe login loop while retaining the existing `platform-admin` admission boundary.

**Architecture:** Dashy and a direct Semaphore UI visit use a `sso-auth@file` UI route to begin the interactive oauth2-proxy login. Semaphore's `/api/*` route uses a non-redirecting `oauth2-auth@file` group gate and owns its user session through Keycloak OIDC. Vault Agent renders the confidential OIDC secret into a dedicated file that Semaphore mounts read-only; it never enters Compose or an environment variable.

**Tech Stack:** Docker Compose, Traefik, oauth2-proxy 7.15.3, Keycloak 26.5.2, Vault Agent, Semaphore UI 2.18.25, Bash contract tests.

## Global Constraints

- `platform-admin` remains mandatory; Semaphore Community cannot enforce this OIDC claim itself.
- `SEMAPHORE_OIDC_PROVIDERS` uses `client_secret_file`, never `client_secret`.
- Semaphore's own API 401 must not be rewritten to `/oauth2/sign_in`.
- Dashy is the primary browser entry point, but a direct unauthenticated Semaphore UI visit must begin oauth2-proxy login; `/api/*` remains a raw 401 when unauthenticated.
- Only `https://dash.imcherry5778.xyz` is allowed as an iframe ancestor.
- Preserve Semaphore PostgreSQL data, API tokens, Vault API routing, and a documented break-glass path.
- Do not trust the pre-existing `semaphore_oidc_client_secret` render file: current Vault data has no `oidc_client_secret` field and the current Vault Agent source has no template for it. Replace it only by the managed render in Task 2.

---

### Task 1: Lock the intended contract with failing tests

**Files:**
- Create: `compose/tests/test-semaphore-native-oidc.sh`
- Modify: `compose/tests/test-dashy-sso-vault.sh`

**Interfaces:**
- Consumes: Semaphore Compose, Traefik dynamic middleware, Vault Agent HCL, Dashy config.
- Produces: an executable contract for native OIDC, secret-file handling, group admission, and iframe headers.

- [ ] **Step 0: Create the implementation branch**

```bash
git switch -c feat/semaphore-native-oidc
```

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
compose="$root/compose/stacks/cicd/semaphore/compose.yaml"
middlewares="$root/compose/stacks/edge/traefik/config/dynamic/middlewares.yaml"
agent="$root/compose/stacks/security/vault-agent/config/agent.hcl"
dashy="$root/compose/stacks/edge/dashy/config/conf.yml"
assert_contains() { grep -Fq -- "$2" "$1" || { echo "FAIL: $2" >&2; exit 1; }; }
assert_not_contains() { ! grep -Fq -- "$2" "$1" || { echo "FAIL: unexpected $2" >&2; exit 1; }; }
assert_contains "$compose" 'SEMAPHORE_OIDC_PROVIDERS:'
assert_contains "$compose" 'client_secret_file'
assert_contains "$compose" '/run/secrets/semaphore_oidc_client_secret:ro,z'
assert_contains "$compose" 'SEMAPHORE_PASSWORD_LOGIN_DISABLED: "true"'
assert_contains "$compose" 'traefik.http.routers.semaphore.middlewares=sso-auth@file,semaphore-iframe@file'
assert_contains "$compose" 'traefik.http.routers.semaphore-api.middlewares=oauth2-auth@file,semaphore-iframe@file'
assert_contains "$agent" 'destination = "/vault/secrets/semaphore_oidc_client_secret"'
assert_contains "$middlewares" 'semaphore-iframe:'
assert_contains "$middlewares" 'frame-ancestors https://dash.imcherry5778.xyz'
assert_contains "$dashy" 'title: Semaphore'
assert_contains "$dashy" 'target: workspace'
```

- [ ] **Step 2: Prove red state**

Run `bash compose/tests/test-semaphore-native-oidc.sh`.

Expected: failure because current Semaphore has neither native OIDC nor a dedicated route policy.

- [ ] **Step 3: Update the existing Dashy test**

Replace only Semaphore's expected middleware in `test-dashy-sso-vault.sh` with `oauth2-auth@file,semaphore-iframe@file`; leave all other service assertions unchanged.

- [ ] **Step 4: Commit**

```bash
git add compose/tests/test-semaphore-native-oidc.sh compose/tests/test-dashy-sso-vault.sh
git commit -m "test(auth): define Semaphore native OIDC contract"
```

### Task 2: Make Keycloak's Semaphore secret Vault-managed

**Files:**
- Create: `compose/scripts/keycloak-semaphore-oidc-bootstrap.sh`
- Modify: `compose/stacks/security/vault-agent/config/agent.hcl`
- Modify: `compose/tests/test-semaphore-vault-env.sh`
- Modify: `compose/tests/test-keycloak-security-groups.sh`

**Interfaces:**
- Consumes: Keycloak admin environment, existing `semaphore` client, and `/tmp/.vt` inside the Vault container.
- Produces: `kv/mgmt/semaphore` field `oidc_client_secret` and render file `/home/mgmt-data/vault-agent/secrets/semaphore_oidc_client_secret` at mode `0640`.

- [ ] **Step 1: Add red assertions**

Add these source assertions and run the two existing tests to confirm failure:

```bash
assert_contains "$vault_agent" 'oidc_client_secret'
assert_contains "$vault_agent" 'destination = "/vault/secrets/semaphore_oidc_client_secret"'
assert_contains "$bootstrap" 'CLIENT_ID=${SEMAPHORE_OIDC_CLIENT_ID:-semaphore}'
assert_contains "$bootstrap" '/api/auth/oidc/keycloak/redirect'
assert_contains "$bootstrap" 'vault kv patch -mount=kv mgmt/semaphore'
```

- [ ] **Step 1a: Verify the supplied Vault token can read the target secret**

Run without printing the token or secret:

```bash
docker exec vault sh -c 'VAULT_TOKEN="$(cat /tmp/.vt)" vault kv get -mount=kv mgmt/semaphore >/dev/null'
```

Expected: exit `0`. If it fails, stop before changing Keycloak because the
client secret cannot be reconciled safely.

- [ ] **Step 2: Implement the Keycloak/Vault bootstrap**

`keycloak-semaphore-oidc-bootstrap.sh` must use these identifiers:

```bash
REALM=${KEYCLOAK_REALM:-mgmt}
CLIENT_ID=${SEMAPHORE_OIDC_CLIENT_ID:-semaphore}
REDIRECT_URI="https://semaphore.${BASE_DOMAIN}/api/auth/oidc/keycloak/redirect"
VAULT_CONTAINER=${VAULT_CONTAINER:-vault}
VAULT_TOKEN_FILE=${VAULT_TOKEN_FILE:-/tmp/.vt}
```

It resolves or creates the confidential Keycloak client, sets standard Authorization Code flow, disables direct grants, replaces redirect URIs with `REDIRECT_URI`, and sets web origins to `https://semaphore.${BASE_DOMAIN}`. It reads the existing client secret, regenerating it only when `SEMAPHORE_ROTATE_OIDC_SECRET=true`. It must pipe that secret into `docker exec -i vault sh -ceu ...` and execute `vault kv patch -mount=kv mgmt/semaphore oidc_client_secret=...` using `VAULT_TOKEN_FILE` inside the Vault container. The script must never print either secret or token.

- [ ] **Step 3: Add an isolated Vault Agent render**

Append this template; do not append the secret to `cicd/semaphore.env`:

```hcl
template {
  contents    = "{{ with secret \"kv/data/mgmt/semaphore\" }}{{ .Data.data.oidc_client_secret }}{{ end }}"
  destination = "/vault/secrets/semaphore_oidc_client_secret"
  perms       = "0640"
}
```

- [ ] **Step 4: Verify and commit**

```bash
bash -n compose/scripts/keycloak-semaphore-oidc-bootstrap.sh
bash compose/tests/test-semaphore-vault-env.sh
bash compose/tests/test-keycloak-security-groups.sh
git add compose/scripts/keycloak-semaphore-oidc-bootstrap.sh compose/stacks/security/vault-agent/config/agent.hcl compose/tests/test-semaphore-vault-env.sh compose/tests/test-keycloak-security-groups.sh
git commit -m "feat(auth): reconcile Semaphore OIDC secret through Vault"
```

Expected: all verification commands exit `0`.

### Task 3: Configure native OIDC and split Semaphore routing

**Files:**
- Modify: `compose/stacks/cicd/semaphore/compose.yaml`
- Modify: `compose/stacks/edge/traefik/config/dynamic/middlewares.yaml`
- Modify: `compose/tests/test-semaphore-native-oidc.sh`
- Modify: `compose/tests/test-dashy-sso-vault.sh`

**Interfaces:**
- Consumes: Vault-rendered secret file and `oauth2-auth@file`.
- Produces: a Keycloak login button, a Semaphore application session, `platform-admin` admission, and Dashy-only iframe framing.

- [ ] **Step 1: Confirm red state**

Run `bash compose/tests/test-semaphore-native-oidc.sh` and confirm the missing OIDC/middleware assertion fails.

- [ ] **Step 2: Add non-secret Compose configuration**

Add this mount:

```yaml
- ${DATA_ROOT:-/home/mgmt-data}/vault-agent/secrets/semaphore_oidc_client_secret:/run/secrets/semaphore_oidc_client_secret:ro,z
```

Add this environment block:

```yaml
SEMAPHORE_PASSWORD_LOGIN_DISABLED: "true"
SEMAPHORE_OIDC_PROVIDERS: >-
  {"keycloak":{"display_name":"Keycloak","provider_url":"https://keycloak.${BASE_DOMAIN}/realms/${KEYCLOAK_REALM:-mgmt}","client_id":"${SEMAPHORE_OIDC_CLIENT_ID:-semaphore}","client_secret_file":"/run/secrets/semaphore_oidc_client_secret","redirect_url":"https://semaphore.${BASE_DOMAIN}/api/auth/oidc/keycloak/redirect","scopes":["openid","profile","email"],"username_claim":"preferred_username","email_claim":"email","name_claim":"name"}}
```

- [ ] **Step 3: Split Semaphore UI and API middleware**

Set the UI and API router labels:

```yaml
- "traefik.http.routers.semaphore.rule=Host(`semaphore.${BASE_DOMAIN}`) && !PathPrefix(`/api`)"
- "traefik.http.routers.semaphore.middlewares=sso-auth@file,semaphore-iframe@file"
- "traefik.http.routers.semaphore-api.rule=Host(`semaphore.${BASE_DOMAIN}`) && PathPrefix(`/api`)"
- "traefik.http.routers.semaphore-api.middlewares=oauth2-auth@file,semaphore-iframe@file"
```

Add this Traefik middleware:

```yaml
semaphore-iframe:
  headers:
    customResponseHeaders:
      X-Frame-Options: ""
      Content-Security-Policy: "frame-ancestors https://dash.imcherry5778.xyz; object-src 'none'"
    contentTypeNosniff: true
    browserXssFilter: true
    stsSeconds: 31536000
    stsIncludeSubdomains: true
```

- [ ] **Step 4: Verify and commit**

```bash
bash compose/tests/test-semaphore-native-oidc.sh
bash compose/tests/test-semaphore-vault-env.sh
bash compose/tests/test-keycloak-security-groups.sh
bash compose/tests/test-oauth2-proxy-stack.sh
bash compose/tests/test-dashy-sso-vault.sh
BASE_DOMAIN=example.test docker compose -f compose/stacks/cicd/semaphore/compose.yaml config --quiet
git add compose/stacks/cicd/semaphore/compose.yaml compose/stacks/edge/traefik/config/dynamic/middlewares.yaml compose/tests/test-semaphore-native-oidc.sh compose/tests/test-dashy-sso-vault.sh
git commit -m "feat(auth): add Semaphore native Keycloak OIDC"
```

Expected: every command exits `0` and rendered Compose contains no OIDC secret.

### Task 4: Deploy and exercise the Dashy iframe path

**Files:**
- Modify: `docs/runbooks/dashy-service-index.md`

**Interfaces:**
- Consumes: merged `main`, Keycloak admin environment, Vault's `/tmp/.vt`, Vault Agent, and a Dashy `platform-admin` browser session.
- Produces: a live native OIDC login path with no Semaphore API redirect loop.

- [ ] **Step 1: Document the deployment order**

```bash
set -a
. /home/mgmt-data/vault-agent/secrets/security/keycloak.env
set +a
BASE_DOMAIN=imcherry5778.xyz bash compose/scripts/keycloak-semaphore-oidc-bootstrap.sh
cd compose
docker compose --env-file ../.env -f stacks/security/vault-agent/compose.yaml up -d --force-recreate
docker compose --env-file ../.env -f stacks/cicd/semaphore/compose.yaml up -d --force-recreate
```

- [ ] **Step 2: Verify live secret and route contracts**

```bash
test -s /home/mgmt-data/vault-agent/secrets/semaphore_oidc_client_secret
test "$(stat -c '%a' /home/mgmt-data/vault-agent/secrets/semaphore_oidc_client_secret)" = 640
curl -ksS -o /dev/null -w '%{http_code}\n' https://semaphore.imcherry5778.xyz/
curl -ksSI https://semaphore.imcherry5778.xyz/api/user | grep -vi '^location:.*oauth2/sign_in'
```

Expected: render file exists at `640`; a direct unauthenticated UI request starts oauth2-proxy login; and an unauthenticated API response does not redirect to oauth2-proxy.

- [ ] **Step 3: Verify a fresh private browser**

1. Sign in to Dashy as `mgmt` in `platform-admin`.
2. Open the Semaphore Workspace tile.
3. Use the Keycloak provider inside Semaphore; Keycloak reuses the session and returns inside the Dashy frame.
4. Confirm the dashboard loads and `/api/user` no longer creates a `Network Error` toast.

- [ ] **Step 4: Final commit, review, merge, and synchronization**

```bash
git add docs/runbooks/dashy-service-index.md
git commit -m "docs: add Semaphore OIDC deployment verification"
git diff --check origin/main...HEAD
git push -u origin HEAD
git push -o merge_request.create -o merge_request.target=main origin HEAD
git switch main
git merge --no-ff feat/semaphore-native-oidc
git push origin main
ssh user1@acer-mgmt 'cd /home/user1/acer-mgmt && git pull --ff-only origin main'
```

Request review for secret exposure, the middleware split, iframe CSP, and preservation of Vault/API automation behavior before merging.
