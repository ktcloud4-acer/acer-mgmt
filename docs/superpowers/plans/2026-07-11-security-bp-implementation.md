# ACER Security Best-Practice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enforce the agreed Keycloak, Teleport, audit, and Wazuh security boundaries on `acer-mgmt` and its managed hosts.

**Architecture:** Native OIDC remains with applications that need local RBAC; oauth2-proxy protects generic web UIs; Teleport protects privileged browser and SSH access. Filebeat and Logstash consolidate audit events in Elasticsearch while Wazuh is deployed separately for host detection and forwards only alerts for correlation.

**Tech Stack:** Docker Compose, Traefik v3, Keycloak 26, Teleport 18, Vault 2, Filebeat/Logstash/Elasticsearch 9, Wazuh, systemd, Tailscale.

## Global Constraints

- Never write secret values to Git, command output, tests, or documentation.
- Preserve Keycloak, Vault, Teleport, and service-local break-glass accounts.
- Keep Keycloak OIDC endpoints and non-HTTP data-plane protocols outside Teleport redirects.
- Use explicit Compose memory limits and persistent `/home/mgmt-data` volumes for Wazuh.
- All privileged direct browser URLs must redirect to a Teleport app or be denied after rollout.

---

### Task 1: Test and implement Keycloak least-privilege mappings

**Files:**
- Modify: `compose/stacks/infra/netbox/config/extra.py`
- Create: `compose/scripts/keycloak-security-groups-bootstrap.sh`
- Create: `compose/tests/test-keycloak-security-groups.sh`

**Interfaces:**
- Consumes: Keycloak realm `mgmt`, group claims, `NETBOX_OIDC_*` environment.
- Produces: `netbox-editor` and `netbox-admin` group-to-role mapping and idempotent group bootstrap.

- [ ] **Step 1: Write the failing test**

```bash
assert_contains "$netbox_extra" '"netbox-admin"'
assert_contains "$netbox_extra" '"netbox-editor"'
assert_contains "$bootstrap" 'ensure_group "netbox-admin"'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash compose/tests/test-keycloak-security-groups.sh`

Expected: `FAIL` because the security-group bootstrap and mapping do not exist.

- [ ] **Step 3: Write minimal implementation**

Add an idempotent Keycloak group bootstrap script and enable a NetBox social-auth
pipeline that synchronizes `netbox-editor` into a NetBox role group and grants
superuser only to `netbox-admin` or the temporary `platform-admin` compatibility
group. NetBox does not use Django's `is_staff` field, so its local group
permissions remain the editor authorization source.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash compose/tests/test-keycloak-security-groups.sh`

Expected: `keycloak security-group tests passed`.

- [ ] **Step 5: Commit**

```bash
git add compose/stacks/infra/netbox/config/extra.py compose/scripts/keycloak-security-groups-bootstrap.sh compose/tests/test-keycloak-security-groups.sh
git commit -m "feat(security): map Keycloak groups to NetBox roles"
```

### Task 2: Test and implement privileged Teleport routes

**Files:**
- Modify: `compose/stacks/security/teleport/config/teleport.yaml`
- Modify: `compose/stacks/edge/traefik/config/dynamic/middlewares.yaml`
- Modify: `compose/stacks/edge/adguard/compose.yaml`
- Create: `compose/tests/test-privileged-teleport-routes.sh`

**Interfaces:**
- Consumes: Teleport public application hosts and Docker service names.
- Produces: Teleport applications for AdGuard, Traefik, MinIO console, and Semaphore plus canonical direct-URL redirects.

- [ ] **Step 1: Write the failing test**

```bash
assert_contains "$teleport_config" 'name: adguard'
assert_contains "$middlewares" 'redirect-to-tp-adguard'
assert_contains "$adguard_stack" 'middlewares=redirect-to-tp-adguard@file'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash compose/tests/test-privileged-teleport-routes.sh`

Expected: `FAIL` because privileged applications and redirects are missing.

- [ ] **Step 3: Write minimal implementation**

Register only Docker-local privileged HTTP UIs with Teleport and add Traefik
redirect middlewares for their canonical browser hosts. Do not redirect API,
DNS, OIDC, SSH, or backend service traffic.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash compose/tests/test-privileged-teleport-routes.sh`

Expected: `privileged Teleport route tests passed`.

- [ ] **Step 5: Commit**

```bash
git add compose/stacks/security/teleport/config/teleport.yaml compose/stacks/edge/traefik/config/dynamic/middlewares.yaml compose/stacks/edge/adguard/compose.yaml compose/tests/test-privileged-teleport-routes.sh
git commit -m "feat(security): gate privileged management UIs with Teleport"
```

### Task 3: Test and implement canonical audit ingestion

**Files:**
- Modify: `compose/stacks/observability/elk/config/filebeat/mgmt-docker-logstash/filebeat.yml`
- Modify: `compose/stacks/observability/elk/config/pipeline/20-filters.conf`
- Create: `compose/stacks/observability/elk/config/kibana/security-audit.ndjson`
- Create: `compose/tests/test-security-audit-pipeline.sh`

**Interfaces:**
- Consumes: Vault file/socket audit JSON, Teleport JSON events, Keycloak event logs, oauth2-proxy logs, Traefik access logs, Wazuh alert JSON.
- Produces: `labels.audit_source`, ECS user/event/source fields, Vault duplicate fingerprint, and an importable Kibana audit dashboard.

- [ ] **Step 1: Write the failing test**

```bash
assert_contains "$filebeat" 'id: mgmt-vault-audit'
assert_contains "$filters" '[labels][audit_source]'
assert_contains "$dashboard" 'Security Audit Overview'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash compose/tests/test-security-audit-pipeline.sh`

Expected: `FAIL` because no canonical audit inputs or dashboard exist.

- [ ] **Step 3: Write minimal implementation**

Add dedicated Filebeat filestream inputs, audit-specific Logstash normalization and
Vault deduplication, and an importable Kibana dashboard with source/user/action/
outcome controls. Do not parse or index secret values.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash compose/tests/test-security-audit-pipeline.sh`

Expected: `security audit pipeline tests passed`.

- [ ] **Step 5: Commit**

```bash
git add compose/stacks/observability/elk compose/tests/test-security-audit-pipeline.sh
git commit -m "feat(audit): ingest security events into Elasticsearch"
```

### Task 4: Test and implement Wazuh central stack and safe agents

**Files:**
- Create: `compose/stacks/security/wazuh/compose.yaml`
- Create: `compose/stacks/security/wazuh/config/agent.conf`
- Create: `compose/stacks/security/wazuh/README.md`
- Create: `compose/systemd/wazuh-agent.service`
- Create: `compose/scripts/install-wazuh-agent.sh`
- Create: `compose/tests/test-wazuh-stack.sh`

**Interfaces:**
- Consumes: Tailscale management address, persistent `DATA_ROOT`, Wazuh agent enrollment key supplied at runtime.
- Produces: Wazuh manager/indexer/dashboard, host-agent configuration, secret exclusions, and JSON alerts mounted for Filebeat.

- [ ] **Step 1: Write the failing test**

```bash
assert_file "$wazuh_stack"
assert_contains "$wazuh_stack" 'wazuh.manager'
assert_contains "$agent_config" '/home/mgmt-data/vault'
assert_contains "$agent_config" 'ignore'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash compose/tests/test-wazuh-stack.sh`

Expected: `FAIL` because the Wazuh stack and secret exclusions do not exist.

- [ ] **Step 3: Write minimal implementation**

Create a memory-bounded central Wazuh Compose stack on `acer-mgmt`; configure
Tailscale-only agent enrollment ports, persistent volumes, JSON alert output, and
host-agent exclusions for all secret-bearing paths.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash compose/tests/test-wazuh-stack.sh`

Expected: `wazuh stack tests passed`.

- [ ] **Step 5: Commit**

```bash
git add compose/stacks/security/wazuh compose/systemd/wazuh-agent.service compose/scripts/install-wazuh-agent.sh compose/tests/test-wazuh-stack.sh
git commit -m "feat(security): add Wazuh host detection stack"
```

### Task 5: Deploy and verify live security boundaries

**Files:**
- Modify: `compose/scripts/verify-security-bp.sh`
- Create: `compose/tests/test-verify-security-bp.sh`

**Interfaces:**
- Consumes: live Docker Compose, Keycloak, Teleport, Filebeat, Elasticsearch, Wazuh, and host-agent state.
- Produces: a read-only health report proving each design boundary.

- [ ] **Step 1: Write the failing test**

```bash
assert_contains "$verify_script" 'tctl apps ls'
assert_contains "$verify_script" 'vault audit list'
assert_contains "$verify_script" 'wazuh-manager'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash compose/tests/test-verify-security-bp.sh`

Expected: `FAIL` because the verifier does not exist.

- [ ] **Step 3: Write minimal implementation**

Implement a read-only verifier covering runtime health, app registration, direct
redirects, audit collector inputs, Keycloak event flags, and Wazuh enrollment.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash compose/tests/test-verify-security-bp.sh`

Expected: `security BP verifier tests passed`.

- [ ] **Step 5: Commit**

```bash
git add compose/scripts/verify-security-bp.sh compose/tests/test-verify-security-bp.sh
git commit -m "test(security): verify BP runtime boundaries"
```

## Execution Handoff

Execute this plan inline in the current session. Each task starts with the
specified failing shell test, uses the smallest configuration change that makes
it pass, then reruns the full Compose shell-test suite before deployment.
