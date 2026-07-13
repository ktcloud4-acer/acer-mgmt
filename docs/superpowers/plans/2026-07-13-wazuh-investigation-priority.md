# Wazuh Investigation Priority Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wazuh level 11 이상을 Immediate investigation에 포함하고, 원본 Wazuh 레벨과 공통 관제 우선순위를 별도 필드와 컬럼으로 표시한다.

**Architecture:** Logstash의 고신호 규칙이 `app.rule.level` 경계에 따라 `labels.audit_alert`와 `labels.alert_severity`를 기록한다. Kibana는 Wazuh 원본 숫자 레벨을 `app.rule.level`에서 직접 읽고, Immediate investigation에서만 제품 공통 우선순위를 함께 보여준다. 기존 문자열 `event.severity`는 과거 문서 호환을 위해 삭제하지 않지만 새 이벤트와 쿼리에서는 사용하지 않는다.

**Tech Stack:** Logstash 9.4.3 filters, Elasticsearch 9.4 mappings and ES|QL, Kibana dashboard API, Bash, jq, Node.js

## Global Constraints

- Wazuh level 11은 `medium`, 12–13은 `high`, 14 이상은 `critical`이다.
- Vault root 토큰 및 민감 `sys/*` 작업은 `critical`을 유지한다.
- 새 문자열 `event.severity`를 기록하지 않는다.
- 과거 문서 삭제, 재색인, `event.severity` 타입 변경은 하지 않는다.
- 기존 `acer-audit-*` 원본과 `acer-audit-alerts-*` 복제 라우팅을 유지한다.

---

### Task 1: Detection policy regression tests

**Files:**
- Modify: `compose/tests/test-security-audit-pipeline.sh`
- Modify: `compose/tests/fixtures/audit-normalization.generator.conf`
- Modify: `compose/tests/test-audit-normalization-logstash.sh`
- Test: `compose/tests/test-security-audit-pipeline.sh`
- Test: `compose/tests/test-audit-normalization-logstash.sh`

**Interfaces:**
- Consumes: Wazuh input at `labels.audit_source=wazuh` with numeric `app.rule.level`.
- Produces: executable contract for level 10, 11, 12, and 14 boundaries plus Vault critical priority.

- [ ] **Step 1: Add failing static policy assertions**

Require `wazuh-investigation-required`, `wazuh-high-severity`, `wazuh-critical`, `labels.alert_severity`, and the 11/12/14 boundaries. Reject new `[event][severity]` writes in `50-audit-alerts.conf`.

- [ ] **Step 2: Add failing behavioral fixtures**

Add generator documents `wazuh-10`, `wazuh-11`, `wazuh-12`, `wazuh-14`, and `vault-root`; mount `50-audit-alerts.conf` after `20-filters.conf`; assert the exact signature and priority matrix with jq.

- [ ] **Step 3: Run tests and confirm RED**

Run:

```bash
bash compose/tests/test-security-audit-pipeline.sh
bash compose/tests/test-audit-normalization-logstash.sh
```

Expected: FAIL because the pipeline still uses level 12 and string `event.severity`.

### Task 2: Detection policy and mappings

**Files:**
- Modify: `compose/stacks/observability/elk/config/pipeline/50-audit-alerts.conf`
- Modify: `compose/stacks/observability/elk/config/ilm/acer-audit.fields.mapping.json`
- Modify: `compose/stacks/observability/elk/config/ilm/acer-audit.template.json`
- Modify: `compose/stacks/observability/elk/README.md`
- Test: `compose/tests/test-security-audit-pipeline.sh`
- Test: `compose/tests/test-audit-normalization-logstash.sh`

**Interfaces:**
- Consumes: numeric Wazuh `app.rule.level` and existing Vault audit fields.
- Produces: `labels.audit_alert` plus keyword `labels.alert_severity`; leaves `event.severity` untouched.

- [ ] **Step 1: Implement mutually exclusive Wazuh boundaries**

Use an `if/else if` chain so each Wazuh event receives at most one signature: level 14+ critical, level 12–13 high, level 11 medium.

- [ ] **Step 2: Move Vault priority to the new field**

Keep existing Vault signatures and write `labels.alert_severity=critical` instead of string `event.severity`.

- [ ] **Step 3: Add the keyword mapping**

Add `labels.alert_severity` as `keyword` in both the template and existing-index mapping payload, keeping the two property trees byte-equivalent after JSON parsing.

- [ ] **Step 4: Document policy and compatibility**

Describe the level matrix, field meanings, and intentional non-migration of historical `event.severity`.

- [ ] **Step 5: Run tests and confirm GREEN**

Run the two Task 1 tests. Expected: both PASS.

### Task 3: Dashboard regression tests

**Files:**
- Modify: `compose/tests/validate-security-audit-dashboard.mjs`
- Test: `compose/tests/validate-security-audit-dashboard.mjs`

**Interfaces:**
- Consumes: dashboard JSON panel titles, ES|QL query strings, and row definitions.
- Produces: a contract that forbids `event.severity` and requires the Wazuh level and priority fields in the correct panels.

- [ ] **Step 1: Add panel-specific failing assertions**

For `Recent high-signal events`, require `labels.alert_severity` and `app.rule.level` in query/rows. For `Wazuh host security`, require `app.rule.level`, label `Wazuh Level`, and no severity field. Reject `event.severity` anywhere in the serialized dashboard.

- [ ] **Step 2: Run validator and confirm RED**

Run:

```bash
node compose/tests/validate-security-audit-dashboard.mjs compose/stacks/observability/elk/config/kibana/security-audit.dashboard.json
```

Expected: FAIL because both tables still use `event.severity`.

### Task 4: Dashboard implementation

**Files:**
- Modify: `compose/stacks/observability/elk/config/kibana/security-audit.dashboard.json`
- Test: `compose/tests/validate-security-audit-dashboard.mjs`

**Interfaces:**
- Consumes: `labels.alert_severity`, `app.rule.level`, and existing normalized audit fields.
- Produces: stable 6-section dashboard with revised columns and unchanged panel IDs/layout.

- [ ] **Step 1: Update Immediate investigation**

Replace `event.severity` with `labels.alert_severity`, add `app.rule.level`, and configure labels `Priority` and `Wazuh Level` in the approved column order.

- [ ] **Step 2: Update Wazuh host security**

Replace `event.severity` with `app.rule.level` and label it `Wazuh Level`; retain endpoint, rule, rule ID, and collector.

- [ ] **Step 3: Run validator and confirm GREEN**

Run the Task 3 validator. Expected: PASS.

### Task 5: Full verification and delivery

**Files:**
- Verify all modified files.

**Interfaces:**
- Consumes: committed configuration and live `acer-mgmt` services.
- Produces: verified main branch and deployed observability configuration.

- [ ] **Step 1: Run local verification**

Run dashboard validation, pipeline contract, Logstash fixture, JSON parsing, Bash syntax, and `git diff --check`.

- [ ] **Step 2: Run remote Logstash fixture**

Execute the fixture against the live host's Logstash 9.4.3 image without changing runtime state.

- [ ] **Step 3: Commit, push, create MR, and merge**

Use Korean conventional commits, create a GitLab MR targeting `main`, verify source SHA and mergeability, merge without squash, and remove the source branch.

- [ ] **Step 4: Synchronize repositories and deploy**

Fast-forward local and `acer-mgmt` remote repositories while preserving unrelated worktree changes. Apply mappings/dashboard, restart Logstash, and verify service health.

- [ ] **Step 5: Verify live behavior**

Confirm live mappings, execute all dashboard ES|QL queries, verify the level 11 records now carry `medium` and appear in the high-signal query, and confirm the Wazuh table returns numeric levels without `event.severity`.

- [ ] **Step 6: Clean up branch and worktree**

Verify local/remote/runtime refs, remove the merged feature worktree and branch, and report preserved unrelated changes.
