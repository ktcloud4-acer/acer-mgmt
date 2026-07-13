# Audit Access Normalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Normalize current proxy and identity text logs into investigation-ready audit fields and reorganize the stable Kibana dashboard by security workflow.

**Architecture:** Filebeat retains team ownership but stops injecting a fake root user. Logstash promotes only successfully parsed Traefik/oauth2-proxy access lines and Keycloak event lines into the canonical audit route, writes compatible `actor.*` and HTTP fields, and Kibana consumes those fields in source-specific panels.

**Tech Stack:** Filebeat 9.4.3, Logstash 9.4.3 grok/kv/mutate/date filters, Elasticsearch 9.4.3 mappings and ES|QL, Kibana 9.4.3 dashboard API, Bash and Node.js contract tests.

## Global Constraints

- Preserve all existing audit documents; do not reindex, update, or delete history.
- Keep stable IDs `acer-audit` and `security-audit-overview`.
- Keep alert-copy exclusion `NOT (_index LIKE "acer-audit-alerts-*")` in every dashboard query.
- Do not stamp individual oauth2-proxy 401 probe responses as high-signal alerts.
- Use `actor.name` for real actors because existing indices map root `user` as text.
- Follow the repository's sequential approval gates before commit, push, MR, merge, runtime synchronization, or branch cleanup.

---

### Task 1: Encode the normalized audit contract

**Files:**
- Modify: `compose/tests/test-security-audit-pipeline.sh`
- Modify: `compose/tests/validate-security-audit-dashboard.mjs`

**Interfaces:**
- Consumes: Filebeat config, Logstash filters, audit mapping/template, apply script, and dashboard JSON.
- Produces: failing assertions for fake-user removal, parser gates, normalized mappings, actor control, source-specific sections, and null-resistant queries.

- [ ] **Step 1: Add ingestion contract assertions**

Require the three source-specific parser branches, `actor.name`, HTTP fields,
`event.outcome`, `observer.name`, and an external existing-index mapping file.
Reject static root `user: mgmt` in the mgmt Filebeat configuration and reject
the old generic three-container audit-source block.

- [ ] **Step 2: Replace dashboard expectations**

Require control fields in this order:

```text
labels.audit_source.keyword
labels.team.keyword
labels.audit_alert
actor.name
host.name.keyword
```

Require sections `Access and authentication` and `Security domains`, 14 ES|QL
queries, and panels `Recent proxy access`, `Authentication failures`,
`Top requested paths`, `Identity and privileged activity`, and
`Wazuh host security`. Reject legacy root-user references.

- [ ] **Step 3: Run focused tests and observe RED**

```powershell
node compose/tests/validate-security-audit-dashboard.mjs compose/stacks/observability/elk/config/kibana/security-audit.dashboard.json
& 'C:\Program Files\Git\bin\bash.exe' compose/tests/test-security-audit-pipeline.sh
```

Expected: failures because the parser, mapping, actor field, and dashboard
sections do not yet exist.

### Task 2: Implement compatible mappings and source normalization

**Files:**
- Create: `compose/stacks/observability/elk/config/ilm/acer-audit.fields.mapping.json`
- Modify: `compose/stacks/observability/elk/config/ilm/acer-audit.template.json`
- Modify: `compose/stacks/observability/elk/config/filebeat/mgmt-docker-logstash/filebeat.yml`
- Modify: `compose/stacks/observability/elk/config/pipeline/20-filters.conf`
- Modify: `compose/stacks/observability/elk/scripts/apply-observability.sh`

**Interfaces:**
- Consumes: observed Traefik combined access format, oauth2-proxy request format, Keycloak event format, and existing audit index mappings.
- Produces: `actor.*`, `observer.name`, `source.ip`, `trace.id`, HTTP, URL, user-agent, category, action, and outcome fields on successfully parsed canonical events.

- [ ] **Step 1: Add the mapping body and template fields**

Create an existing-index mapping body with explicit types from the design and
copy the same properties into the audit index template. Preserve
`labels.audit_alert` as keyword and `url.path` as text plus keyword.

- [ ] **Step 2: Apply the mapping body idempotently**

Replace the hard-coded `audit_alert` mapping request in
`apply-observability.sh` with `-d @"$CFG/ilm/acer-audit.fields.mapping.json"`.
Keep this step before Kibana data-view provisioning.

- [ ] **Step 3: Remove the fake Filebeat user**

Remove every root-level `user: mgmt` under the mgmt Filebeat `fields` blocks;
retain `labels.team: mgmt` and all routing metadata.

- [ ] **Step 4: Gate and parse container audit sources**

Replace the generic container-name promotion block with separate Traefik,
oauth2-proxy, and Keycloak parsers. Add `labels.audit_source`, service, module,
and `event.kind` only after the source format parses successfully. Leave failed
or unrelated lines on the normal Docker route.

- [ ] **Step 5: Normalize identities and observer host**

Write Vault/Teleport/Keycloak/oauth2 actors to `actor.name`, stable IDs to
`actor.id`, and retain the collector in `observer.name` before Wazuh replaces
`host.name` with its endpoint agent.

- [ ] **Step 6: Run the pipeline contract and observe GREEN**

```powershell
& 'C:\Program Files\Git\bin\bash.exe' compose/tests/test-security-audit-pipeline.sh
```

Expected: the ingestion and mapping assertions pass; dashboard assertions may
remain red until Task 3.

### Task 3: Rebuild the operational dashboard

**Files:**
- Modify: `compose/stacks/observability/elk/config/kibana/security-audit.dashboard.json`
- Modify: `compose/tests/validate-security-audit-dashboard.mjs`

**Interfaces:**
- Consumes: normalized fields from Task 2 and stable data-view ID `acer-audit`.
- Produces: six workflow-oriented sections and 14 time-bound ES|QL panels.

- [ ] **Step 1: Replace the actor control and common query scope**

Use `actor.name`. In every query, exclude alert copies and historical
Traefik/oauth2-proxy/Keycloak rows whose `event.action` is null.

- [ ] **Step 2: Keep situation, coverage, and high-signal workflows**

Retain the four KPI and three coverage panels. Update the high-signal table to
show actor, action, outcome, host, and the guaranteed alert signature.

- [ ] **Step 3: Add access and authentication panels**

Create a 32-column recent-access table and two stacked 16-column charts for
authentication failures and top requested paths.

- [ ] **Step 4: Add security-domain panels**

Create equal-width identity/privileged and Wazuh host-security tables with
fields specific to their sources.

- [ ] **Step 5: Simplify the full timeline**

Show only time, source, service, actor, host, action, outcome, and message.

- [ ] **Step 6: Run both focused tests and observe GREEN**

Run both commands from Task 1. Expected: dashboard validator and pipeline
contract exit 0.

### Task 4: Verify implementation and prepare Git handoff

**Files:**
- Verify: every file modified or created in Tasks 1–3.

**Interfaces:**
- Consumes: completed repository change.
- Produces: local evidence and, after Git approvals, live field/sample/dashboard/health evidence.

- [ ] **Step 1: Validate JSON and shell/Logstash syntax**

Parse all three JSON artifacts, run `bash -n` on shell scripts, and run a
Logstash `--config.test_and_exit` check against the merged pipeline on the mgmt
host before restarting it.

- [ ] **Step 2: Run focused regression tests**

Run the Node dashboard validator and Bash security audit pipeline test from a
fresh process and require exit 0.

- [ ] **Step 3: Inspect diff and repository state**

Run `git diff --check`, `git diff --stat`, `git diff`, and `git status --short`.
Confirm only the listed files and the two approved documents changed.

- [ ] **Step 4: Report and request sequential Git approvals**

Request commit, push, MR, merge, and runtime/local/remote synchronization in
the order required by `AGENTS.md`; uppercase `Y` approves all steps.
