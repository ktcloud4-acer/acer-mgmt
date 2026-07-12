# OAuth2 Proxy RedisInsight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Store OAuth2 Proxy sessions in private Redis and provide a Keycloak-protected RedisInsight UI at `redis.imcherry5778.xyz`.

**Architecture:** The OAuth2 Proxy Compose stack adds a persistent Redis service on an internal network and configures OAuth2 Proxy with Redis session storage. RedisInsight joins both the session and Traefik proxy networks, while Traefik routes only its HTTPS UI through the existing `sso-auth@file` middleware.

**Tech Stack:** Docker Compose, Redis, RedisInsight, OAuth2 Proxy v7.15.3, Traefik v3, Keycloak OIDC, Dashy.

## Global Constraints

- Do not publish Redis TCP port 6379 or attach Redis directly to `mgmt-proxy`.
- Keep `platform-admin` as the sole outer-access group through existing OAuth2 Proxy policy.
- Keep all credential values outside Git.
- Add source tests before changing runtime configuration.

---

### Task 1: Define and verify the private session stack

**Files:**
- Modify: `compose/tests/test-oauth2-proxy-stack.sh`
- Modify: `compose/stacks/security/oauth2-proxy/compose.yaml`

- [ ] Add assertions for Redis session storage, the internal session network, Redis persistence, no Redis port publication, and RedisInsight's SSO route.
- [ ] Run `bash compose/tests/test-oauth2-proxy-stack.sh` and confirm it fails before configuration is added.
- [ ] Add `oauth2-proxy-redis` and `redisinsight` services, named volumes, and an internal `oauth2-proxy-session` network.
- [ ] Configure OAuth2 Proxy with `--session-store-type=redis` and a Docker-internal Redis URL.
- [ ] Run `bash compose/tests/test-oauth2-proxy-stack.sh` and confirm it passes.

### Task 2: Publish discoverable management access

**Files:**
- Create: `compose/scripts/configure-redisinsight-dns.sh`
- Modify: `compose/tests/test-dns-smoke-test.sh`
- Modify: `compose/stacks/edge/dashy/config/conf.yml`
- Modify: `compose/tests/test-dashy-service-index.sh`

- [ ] Add DNS and Dashy assertions, then run each test to observe the expected failure.
- [ ] Add an idempotent AdGuard rewrite script for `redis.${BASE_DOMAIN}`.
- [ ] Add a RedisInsight Security item to Dashy and include the hostname in DNS smoke coverage.
- [ ] Run the DNS and Dashy tests again and confirm they pass.

### Task 3: Deploy and prove the access path

**Files:**
- Modify: `compose/stacks/security/oauth2-proxy/README.md`

- [ ] Document the Redis session store, private port policy, and RedisInsight access path.
- [ ] Validate Compose rendering with `docker compose config` using the runtime environment.
- [ ] Deploy the refreshed OAuth2 Proxy stack and run the DNS script.
- [ ] Create or verify the external exact DNS record without committing credentials.
- [ ] Verify containers, no Redis port publication, HTTPS redirect to Keycloak when unauthenticated, and authenticated UI access.

