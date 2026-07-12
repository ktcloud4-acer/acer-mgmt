# Wazuh Dashboard Publication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish Wazuh Dashboard through Traefik and Dashy while retaining its private backend listener.

**Architecture:** Traefik routes the canonical Wazuh hostname through the existing Keycloak forward-auth middleware to the Dashboard HTTPS service on `mgmt-proxy`. Dashy links only to this canonical route.

**Tech Stack:** Docker Compose, Traefik dynamic file provider, Dashy YAML, Keycloak Admin CLI.

## Global Constraints

- Do not publish port 5601 or 5602 beyond loopback.
- Use `sso-auth@file,secure-headers@file` at the public router.
- Preserve Wazuh's internal authentication until a separate native SAML migration.

### Task 1: Declare the protected route

**Files:**
- Create: `compose/stacks/edge/traefik/config/dynamic/wazuh.yaml`
- Modify: `compose/stacks/edge/traefik/compose.yaml`
- Test: `compose/tests/test-wazuh-dashboard-publication.sh`

- [ ] Add a failing test for the Wazuh hostname, protected router, HTTPS backend, and transport.
- [ ] Add the minimal Traefik router/service/transport declarations.
- [ ] Run `bash compose/tests/test-wazuh-dashboard-publication.sh` and `docker compose ... config --quiet`.

### Task 2: Publish the service index and future roles

**Files:**
- Modify: `compose/stacks/edge/dashy/config/conf.yml`
- Modify: `compose/scripts/keycloak-security-groups-bootstrap.sh`
- Test: `compose/tests/test-wazuh-dashboard-publication.sh`

- [ ] Add failing assertions for the Dashy Security item and Keycloak role groups.
- [ ] Add the canonical Dashy item and idempotent group declarations.
- [ ] Re-run the test and the full Compose test suite.

### Task 3: Deploy and verify

- [ ] Reconcile Keycloak groups and reload Traefik.
- [ ] Verify public URL redirects through OAuth2 Proxy without exposing port 5602.
- [ ] Commit, push, merge, synchronize the host checkout, and verify runtime health.
