# Security Audit Kibana Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provision a reviewable, idempotent Kibana dashboard that supports security-audit collection monitoring, triage, pivots, and event-level investigation without double-counting alert-routing copies.

**Architecture:** A stable default-space data view excludes `acer-audit-alerts-*`, while one Kibana 9.4 Dashboards API JSON payload owns the complete dashboard state under a fixed ID. `apply-observability.sh` upserts the data view, replaces the dashboard, and verifies it by GET; a static contract test validates JSON, layout, queries, and fail-closed provisioning.

**Tech Stack:** Bash, curl, Elasticsearch ES|QL, Kibana 9.4.3 Data Views API, Kibana 9.4 Dashboards API, JSON.

## Global Constraints

- Target Elastic Stack is pinned to `9.4.3`; the Dashboards API is Technical Preview added in Kibana 9.4.
- Use the 48-column Kibana grid and the scan order KPI → trend/coverage → urgent events → pivots → timeline.
- Use only the current normalized audit fields documented in `docs/superpowers/specs/2026-07-13-security-audit-kibana-dashboard-design.md`.
- Exclude `acer-audit-alerts-*` from analytical counts because it contains additive copies of canonical high-signal events.
- Use stable IDs `acer-audit` and `security-audit-overview`.
- Never write directly to the `.kibana` index or hand-edit an exported saved-object NDJSON structure.
- Do not commit, push, open a PR, merge, or clean branches until the repository's ordered `y/n` approval flow is followed.

## File structure

- Create `compose/stacks/observability/elk/config/kibana/security-audit.dashboard.json`: complete Dashboards API request body and single source of truth.
- Delete `compose/stacks/observability/elk/config/kibana/security-audit.ndjson`: obsolete empty dashboard definition.
- Modify `compose/stacks/observability/elk/scripts/apply-observability.sh`: fail-closed data-view/dashboard upsert and read-back verification.
- Modify `compose/tests/test-security-audit-pipeline.sh`: dashboard and provisioning contract test.
- Create `compose/tests/validate-security-audit-dashboard.mjs`: semantic JSON/layout/query validator using only Node.js standard libraries.
- Modify `compose/stacks/observability/elk/README.md`: operator-facing provisioned asset and compatibility notes.
- Modify `docs/runbooks/audit-hardening-w0-2026-07-12.md`: deployment verification commands and dashboard access check.

---

### Task 1: Lock the dashboard contract with a failing test

**Files:**
- Modify: `compose/tests/test-security-audit-pipeline.sh`
- Create: `compose/tests/validate-security-audit-dashboard.mjs`
- Test: `compose/tests/test-security-audit-pipeline.sh`

**Interfaces:**
- Consumes: dashboard ID `security-audit-overview`, data-view ID `acer-audit`, canonical pattern `acer-audit-*,-acer-audit-alerts-*`.
- Produces: a static contract that later tasks must satisfy.

- [ ] **Step 1: Point the test at the declarative JSON payload**

Replace the old path with:

```bash
dashboard="$ROOT_DIR/compose/stacks/observability/elk/config/kibana/security-audit.dashboard.json"
```

- [ ] **Step 2: Add a semantic dashboard validator**

Create a Node.js validator that loads the JSON, verifies the five ordered
section titles, five pinned controls, four metric panels, stable and unique
IDs, grid bounds, non-overlap inside each section, and required operational
panel titles. Recursively collect every `data_source.type == "esql"` query and
require both the time boundary and `NOT (_index LIKE
\"acer-audit-alerts-*\")` in every query. End with:

```javascript
import { readFileSync } from "node:fs";

const dashboard = JSON.parse(readFileSync(process.argv[2], "utf8"));
// Assert the exact section order, control fields, stable IDs, 48-column
// layouts, non-overlap, operational panel titles, and every ES|QL boundary.
console.log("security audit dashboard contract valid");
```

The validator exits non-zero with a descriptive assertion when any invariant
is broken.

- [ ] **Step 3: Invoke the validator portably from Bash**

Add a helper that invokes the dependency-free Node.js validator:

```bash
assert_dashboard_contract() {
  local file="$1"
  command -v node >/dev/null 2>&1 || fail "node is required to validate dashboard JSON"
  node "$ROOT_DIR/compose/tests/validate-security-audit-dashboard.mjs" "$file"
}
```

- [ ] **Step 4: Assert the operational hierarchy and provisioning contract**

Add exact content assertions for:

```bash
assert_dashboard_contract "$dashboard"
assert_contains "$dashboard" '"title": "Security Audit Overview"'
assert_contains "$dashboard" '"type": "options_list_control"'
assert_contains "$dashboard" '"field_name": "labels.audit_source.keyword"'
assert_contains "$dashboard" '"field_name": "labels.team.keyword"'
assert_contains "$dashboard" '"field_name": "labels.audit_alert.keyword"'
assert_contains "$dashboard" '"field_name": "user.name.keyword"'
assert_contains "$dashboard" '"field_name": "host.name.keyword"'
assert_contains "$dashboard" 'SET unmapped_fields=\"NULLIFY\"; FROM acer-audit-* METADATA _index'
assert_contains "$dashboard" 'Current situation'
assert_contains "$dashboard" 'Source freshness'
assert_contains "$dashboard" 'Recent high-signal events'
assert_contains "$dashboard" 'Full audit timeline'
assert_contains "$dashboard" 'NOT (_index LIKE \"acer-audit-alerts-*\")'
assert_contains "$dashboard" '"id": "audit-kpi-total"'
assert_contains "$apply" 'acer-audit-*,-acer-audit-alerts-*'
assert_contains "$apply" '/api/dashboards/security-audit-overview'
assert_contains "$apply" 'security-audit.dashboard.json'
assert_contains "$apply" 'dashboard verification failed'
```

- [ ] **Step 5: Run the test and verify the new contract fails**

Run:

```bash
bash compose/tests/test-security-audit-pipeline.sh
```

Expected: `FAIL: missing file: .../security-audit.dashboard.json`.

---

### Task 2: Add the complete operations-first dashboard payload

**Files:**
- Create: `compose/stacks/observability/elk/config/kibana/security-audit.dashboard.json`
- Delete: `compose/stacks/observability/elk/config/kibana/security-audit.ndjson`
- Test: `compose/tests/validate-security-audit-dashboard.mjs`
- Test: `compose/tests/test-security-audit-pipeline.sh`

**Interfaces:**
- Consumes: canonical audit indices and normalized fields from the Logstash pipeline.
- Produces: a valid body for `PUT /api/dashboards/security-audit-overview` referencing data-view ID `acer-audit` only from pinned controls.

- [ ] **Step 1: Add dashboard metadata and defaults**

The root object must contain:

```json
{
  "title": "Security Audit Overview",
  "description": "Canonical security audit triage and investigation. Alert-routing copies are excluded to prevent double counting.",
  "time_range": { "from": "now-24h", "to": "now", "mode": "relative" },
  "refresh_interval": { "pause": false, "value": 60000 },
  "query": { "language": "kql", "expression": "" },
  "options": {
    "hide_panel_titles": false,
    "hide_panel_borders": false,
    "use_margins": true,
    "auto_apply_filters": true,
    "sync_colors": false,
    "sync_cursor": true,
    "sync_tooltips": true
  }
}
```

- [ ] **Step 2: Add five pinned controls**

Each control uses `data_view_id: "acer-audit"`, `use_global_filters: true`,
wildcard search, and descending document-count sort. Add source, team, alert
signature, user, and host controls with the `.keyword` field names in Task 1.
Assign stable IDs `audit-control-source`, `audit-control-team`,
`audit-control-alert`, `audit-control-user`, and `audit-control-host`.

- [ ] **Step 3: Add four situation KPIs**

Use four 12-column ES|QL metric panels. Every query begins with this
optional-field-safe canonical time/index boundary:

```text
SET unmapped_fields="NULLIFY";
FROM acer-audit-* METADATA _index
| WHERE @timestamp >= ?_tstart AND @timestamp < ?_tend
  AND NOT (_index LIKE "acer-audit-alerts-*")
```

Complete the queries with:

```text
| STATS events = COUNT(*)
| WHERE labels.audit_alert IS NOT NULL | STATS events = COUNT(*)
| WHERE labels.audit_source.keyword == "wazuh" | STATS events = COUNT(*)
| STATS sources = COUNT_DISTINCT(labels.audit_source.keyword)
```

Bind the returned `events` or `sources` column as a primary metric and label it
`Events`, `High signal`, `Wazuh alerts`, or `Active sources`.

- [ ] **Step 4: Add trend and collection coverage panels**

Use a 32-column line chart with:

```text
| STATS events = COUNT(*) BY bucket = BUCKET(@timestamp, 75, ?_tstart, ?_tend), source = labels.audit_source.keyword
```

Bind `bucket` to X, `events` to Y, and `source` to `breakdown_by`. Beside it,
place a 16-column horizontal source-volume bar and a 16-column source-freshness
table using:

```text
| STATS events = COUNT(*) BY source = labels.audit_source.keyword | SORT events DESC | LIMIT 10
| STATS events = COUNT(*), last_seen = MAX(@timestamp) BY source = labels.audit_source.keyword | SORT last_seen ASC
```

- [ ] **Step 5: Add high-signal and behavioral investigation panels**

The high-signal table filters `labels.audit_alert IS NOT NULL`, sorts
`@timestamp DESC`, keeps the exact normalized investigation fields, and limits
results to 100. Add horizontal bar pivots for top action, top user, and top host
with limits of 15, 10, and 10 respectively. Use these exact query suffixes:

```text
| WHERE labels.audit_alert IS NOT NULL
| SORT @timestamp DESC
| KEEP @timestamp, event.severity, labels.audit_alert, labels.audit_source, labels.team, user.name, host.name, event.action, event.code, url.path
| LIMIT 100

| WHERE event.action IS NOT NULL | STATS events = COUNT(*) BY action = event.action.keyword | SORT events DESC | LIMIT 15
| WHERE user.name IS NOT NULL | STATS events = COUNT(*) BY user = user.name.keyword | SORT events DESC | LIMIT 10
| WHERE host.name IS NOT NULL | STATS events = COUNT(*) BY host = host.name.keyword | SORT events DESC | LIMIT 10
```

- [ ] **Step 6: Add the full audit timeline**

Use a full-width ES|QL data table, newest first, with a limit of 200 and these
columns:

```text
@timestamp, labels.audit_source, labels.team, labels.service,
event.severity, labels.audit_alert, user.name, host.name,
event.action, event.code, url.path, message
```

- [ ] **Step 7: Use five top-level sections on the 48-column grid**

Use these section Y coordinates and nested panel dimensions:

| Section | Y | Nested layout |
|---|---:|---|
| Current situation | 0 | four `12x6` KPIs |
| Trend and collection coverage | 9 | `32x14` trend; two `16x7` right panels |
| Immediate investigation | 26 | one `48x16` table |
| Behavioral pivots | 45 | `24x13`, `12x13`, `12x13` |
| Full audit timeline | 61 | one `48x20` table |

Assign the five section IDs `audit-section-situation`,
`audit-section-coverage`, `audit-section-immediate`, `audit-section-pivots`,
and `audit-section-timeline`. Assign the twelve panel IDs
`audit-kpi-total`, `audit-kpi-high-signal`, `audit-kpi-wazuh`,
`audit-kpi-sources`, `audit-trend-events`, `audit-trend-sources`,
`audit-table-freshness`, `audit-table-high-signal`, `audit-pivot-actions`,
`audit-pivot-users`, `audit-pivot-hosts`, and `audit-table-timeline`.

- [ ] **Step 8: Remove the obsolete NDJSON and run the focused test**

Run:

```bash
bash compose/tests/test-security-audit-pipeline.sh
```

Expected: it still fails on missing provisioning strings in
`apply-observability.sh`, proving the payload contract is now satisfied and the
next production boundary is still unimplemented.

---

### Task 3: Provision and verify the dashboard idempotently

**Files:**
- Modify: `compose/stacks/observability/elk/scripts/apply-observability.sh`
- Test: `compose/tests/test-security-audit-pipeline.sh`

**Interfaces:**
- Consumes: `config/kibana/security-audit.dashboard.json`.
- Produces: stable data view `acer-audit` and stable dashboard `security-audit-overview`; exits non-zero on a Kibana failure.

- [ ] **Step 1: Add a fatal-error helper and payload path**

Add:

```bash
AUDIT_DASHBOARD="$CFG/kibana/security-audit.dashboard.json"
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
```

- [ ] **Step 2: Make data-view writes convergent and fail-closed**

Change `mk_dataview` to submit `"override":true`, set
`"allowNoIndex":true` inside `data_view`, and use `curl -sf`. A failed request
must call `die "data view $id provisioning failed"`; a successful request
prints `data_view $id ok`.

- [ ] **Step 3: Create the canonical default-space audit data view**

After the existing admin data views, call:

```bash
mk_dataview "-" "acer-audit-*,-acer-audit-alerts-*" "acer-audit"
```

- [ ] **Step 4: Replace the dashboard through the fixed-ID API**

Use:

```bash
curl -sf -X PUT "$KB/api/dashboards/security-audit-overview" "${KBH[@]}" \
  -d @"$AUDIT_DASHBOARD" >/dev/null \
  || die "security audit dashboard provisioning failed"
```

- [ ] **Step 5: Read the dashboard back and verify identity and title**

Capture `GET /api/dashboards/security-audit-overview`. Fail unless the response
contains both compact JSON fragments below:

```text
"id":"security-audit-overview"
"title":"Security Audit Overview"
```

The failure text must contain `dashboard verification failed` so the static
test locks the behavior.

- [ ] **Step 6: Run the focused test**

Run:

```bash
bash compose/tests/test-security-audit-pipeline.sh
```

Expected: `security audit pipeline tests passed`.

---

### Task 4: Document operation and perform proportional verification

**Files:**
- Modify: `compose/stacks/observability/elk/README.md`
- Modify: `docs/runbooks/audit-hardening-w0-2026-07-12.md`
- Test: `compose/tests/test-security-audit-pipeline.sh`

**Interfaces:**
- Consumes: the implemented data-view/dashboard provisioning contract.
- Produces: deployment and operator guidance that matches the code.

- [ ] **Step 1: Document the provisioned audit dashboard**

Add the stable IDs, canonical pattern, last-24-hour/60-second defaults, five
filter controls, section scan order, and the reason alert-routing copies are
excluded. State that Kibana 9.4 Dashboards API is Technical Preview and the
stack is pinned to 9.4.3.

- [ ] **Step 2: Add runbook verification commands**

Add authenticated checks for:

```bash
curl -sf -u "elastic:$ELK_ELASTIC_PASSWORD" \
  http://127.0.0.1:5601/api/data_views/data_view/acer-audit | jq -e '.data_view.title'
curl -sf -u "elastic:$ELK_ELASTIC_PASSWORD" \
  http://127.0.0.1:5601/api/dashboards/security-audit-overview \
  | jq -e '.id == "security-audit-overview" and .data.title == "Security Audit Overview"'
```

- [ ] **Step 3: Run JSON, shell, and focused repository validation**

Run:

```bash
bash -n compose/stacks/observability/elk/scripts/apply-observability.sh
bash -n compose/tests/test-security-audit-pipeline.sh
bash compose/tests/test-security-audit-pipeline.sh
```

Expected: both syntax checks return zero and the focused test prints
`security audit pipeline tests passed`.

- [ ] **Step 4: Inspect the final diff and whitespace**

Run:

```bash
git diff --check
git status --short
git diff -- compose/stacks/observability/elk/config/kibana/security-audit.dashboard.json \
  compose/stacks/observability/elk/scripts/apply-observability.sh \
  compose/tests/test-security-audit-pipeline.sh \
  compose/stacks/observability/elk/README.md \
  docs/runbooks/audit-hardening-w0-2026-07-12.md
```

Expected: no whitespace errors; only intended files plus pre-existing unrelated
working-tree changes are present.

- [ ] **Step 5: Report completion and request Git approval**

Report changed assets, exact verification results, and any live-runtime check
that could not be executed. Then ask `commit? (y/n)` as the first repository
approval step; do not perform later Git actions early.
