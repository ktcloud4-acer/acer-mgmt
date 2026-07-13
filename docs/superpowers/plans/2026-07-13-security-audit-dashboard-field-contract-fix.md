# Security Audit Dashboard Field Contract Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the broken audit controls and populate actor views using the live Elasticsearch field contract without rewriting audit history.

**Architecture:** The dashboard consumes scalar actor field `user` and its aggregatable `user.keyword` multi-field. `labels.audit_alert` becomes an explicitly mapped keyword for both existing and future audit indices before Kibana recreates its data view and dashboard.

**Tech Stack:** Elasticsearch index templates and mapping API, Kibana dashboard API/ES|QL, Bash contract tests, Node.js JSON validator.

## Global Constraints

- Preserve existing audit documents; do not run update-by-query or backfill.
- Preserve stable IDs `acer-audit` and `security-audit-overview`.
- Preserve exclusion of `acer-audit-alerts-*` copies from canonical counts.
- Follow the repository's sequential user approval gates before commit, push, MR, merge, deployment synchronization, or branch cleanup.

---

### Task 1: Encode the corrected field contract

**Files:**
- Modify: `compose/tests/test-security-audit-pipeline.sh`
- Modify: `compose/tests/validate-security-audit-dashboard.mjs`

**Interfaces:**
- Consumes: dashboard JSON and audit index-template files.
- Produces: regression checks for `labels.audit_alert`, `user.keyword`, scalar `user` table columns, and `Wazuh audit events` wording.

- [ ] **Step 1: Replace the obsolete expected control fields**

Require `labels.audit_alert` and `user.keyword`, and reject
`labels.audit_alert.keyword` and `user.name.keyword` anywhere in the dashboard.

- [ ] **Step 2: Require the corrected actor queries and mapping contract**

Assert that Top users aggregates `user.keyword`, tables keep scalar `user`, the
template maps `labels.audit_alert` as `keyword`, and the apply script updates
existing audit-index mappings.

- [ ] **Step 3: Run the focused tests and observe RED**

Run:

```powershell
node compose/tests/validate-security-audit-dashboard.mjs compose/stacks/observability/elk/config/kibana/security-audit.dashboard.json
& 'C:\Program Files\Git\bin\bash.exe' compose/tests/test-security-audit-pipeline.sh
```

Expected: failure because the dashboard and template still contain the old
contract.

### Task 2: Implement the dashboard and mapping fix

**Files:**
- Modify: `compose/stacks/observability/elk/config/kibana/security-audit.dashboard.json`
- Modify: `compose/stacks/observability/elk/config/ilm/acer-audit.template.json`
- Modify: `compose/stacks/observability/elk/scripts/apply-observability.sh`

**Interfaces:**
- Consumes: existing `acer-audit-*` mappings and stable Kibana dashboard/data-view IDs.
- Produces: a mapped alert-signature keyword, working actor filters/aggregations, and accurate Wazuh KPI wording.

- [ ] **Step 1: Add the explicit alert mapping**

Add `template.mappings.properties.labels.properties.audit_alert.type =
"keyword"` and an idempotent `PUT /acer-audit-*/_mapping` call before Kibana
data-view provisioning.

- [ ] **Step 2: Correct dashboard fields**

Use `labels.audit_alert` and `user.keyword` for options controls, aggregate Top
users by `user.keyword`, and keep/display scalar `user` in both investigation
tables.

- [ ] **Step 3: Correct KPI semantics**

Rename the Wazuh metric title and label to `Wazuh audit events` and describe it
as normalized Wazuh audit events.

- [ ] **Step 4: Run focused tests and observe GREEN**

Run the two commands from Task 1. Expected: both exit 0 with the dashboard
contract and pipeline tests passing.

### Task 3: Verify and prepare Git handoff

**Files:**
- Verify only: all modified files and live mgmt deployment after approval.

**Interfaces:**
- Consumes: corrected repository configuration.
- Produces: local test evidence, then live field-cap/dashboard/health evidence after merge approval.

- [ ] **Step 1: Validate JSON and shell syntax**

Run `node` validator, `python -m json.tool` for both JSON files, and
`bash -n` for the apply script.

- [ ] **Step 2: Review the exact diff and worktree status**

Run `git diff --check`, `git diff --stat`, `git diff`, and `git status --short`.

- [ ] **Step 3: Report results and request Git approvals**

Ask sequentially for commit, push, MR, merge, and runtime/local/remote
synchronization as required by `AGENTS.md`; uppercase `Y` approves all steps.
