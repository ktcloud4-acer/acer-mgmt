# Security Audit Kibana Dashboard Design

**Date:** 2026-07-13

**Owner:** acer-mgmt

**Target:** Elastic Stack 9.4.3 / Kibana Dashboards API 9.4

## 1. Goal

Provide an operations-first Kibana dashboard for the shared security audit
stream. The dashboard must let an operator answer, in order:

1. Is audit collection alive and how much activity is occurring?
2. Are there high-signal events that require immediate investigation?
3. Which source, team, actor, host, and action explain the change?
4. What are the exact recent events needed for follow-up?

Kibana remains the unified investigation surface. Wazuh remains a host
detection engine and supplies actionable alerts; it is not used as the sole
storage or visualization system for all audit sources.

## 2. Current field contract

The dashboard uses only fields already normalized by the Logstash pipeline:

| Purpose | Field | Notes |
|---|---|---|
| Event time | `@timestamp` | Global time picker and all trend queries |
| Team | `labels.team` | Shared administrative filtering |
| Source | `labels.audit_source` | Teleport, Vault, Wazuh, Keycloak, oauth2-proxy, Traefik |
| Service | `labels.service` | Source-side service label |
| High-signal rule | `labels.audit_alert` | String such as `vault-root-token-used`; absent on normal events |
| Severity | `event.severity` | Currently `critical` or `high` on high-signal rules |
| Action | `event.action` | Normalized for Teleport, Vault, and Wazuh |
| Rule/event code | `event.code` | Teleport/Wazuh identifiers where available |
| Actor | `user.name` | Teleport/Vault where available |
| Host | `host.name` | Wazuh agent where available |
| Resource path | `url.path` | Vault request path where available |
| Fallback context | `message` | Raw contextual message for sources without full normalization |

The initial dashboard intentionally does not depend on `event.outcome`,
`source.ip`, or `service.name`, because those fields are not normalized
consistently across the current sources.

The current indices rely on dynamic string mappings, so filter controls and
grouping/count-distinct operations use each field's aggregatable `.keyword`
subfield. Tables continue to display the base field. Every ES|QL query starts
with `SET unmapped_fields="NULLIFY";` so optional fields that have not appeared
in an index yet become null instead of failing the whole panel.

## 3. Counting boundary and duplicate prevention

The Logstash consumer writes a high-signal event twice:

- canonical copy: `acer-audit-<team>-*`
- alert routing copy: `acer-audit-alerts-<team>-*`

Therefore a plain `acer-audit-*` query double-counts high-signal events. The
dashboard uses the canonical boundary below:

- data view: `acer-audit-*,-acer-audit-alerts-*`
- ES|QL panels: load `_index` metadata and exclude
  `acer-audit-alerts-*`

High-signal panels then filter the canonical event on
`labels.audit_alert IS NOT NULL`. The alert index remains available for alert
routing and dedicated searches, but is not an analytical source for this
dashboard.

## 4. Information architecture

The layout follows Kibana's 48-column grid and the operator's scanning order:

### Pinned filter strip

Always visible controls for source, team, alert signature, user, and host,
using their `.keyword` subfields.
The global time picker remains the primary time control. Controls use the
stable `acer-audit` data-view ID so the dashboard can be recreated safely.

### Section A — Current situation

Four equal KPI panels, each 12 columns wide:

- total canonical events
- high-signal events
- Wazuh alerts
- active audit sources

This row is limited to quantities that change an operator's next action.

### Section B — Trend and collection coverage

- 32-column event trend, broken down by audit source
- 16-column source volume ranking
- 16-column source freshness table showing event count and last-seen time

Volume and freshness are kept together: a quiet source and a broken collector
must not look identical.

### Section C — Immediate investigation

A full-width recent high-signal table sorted newest first. It exposes time,
severity, alert signature, source, team, actor, host, action, event code, and
resource path.

### Section D — Behavioral pivots

- top actions: 24 columns
- top users: 12 columns
- top hosts: 12 columns

The split keeps user-oriented access audit and host-oriented Wazuh activity
visible without inventing a synthetic identity field.

### Section E — Full audit timeline

A full-width, newest-first table for the current filters and time range. It
contains the normalized investigation fields plus the fallback message.

## 5. Dashboard defaults

- time range: last 24 hours
- auto refresh: 60 seconds, enabled
- panel margins and borders: enabled
- titles: visible and operationally named
- global filters: applied to every panel
- source queries: full sampling

The dashboard is intended for triage and investigation, not reporting. It
does not add decorative markdown, gauges without thresholds, or charts that
duplicate the same question.

## 6. Provisioning design

The repository owns one declarative JSON payload and applies it through the
official Kibana 9.4 Dashboards API:

1. Upsert the stable `acer-audit` data view with `override: true` and
   `allowNoIndex: true`, so first-time provisioning can precede data arrival.
2. `PUT /api/dashboards/security-audit-overview` with the complete dashboard
   state and fixed ID. Sections, controls, and panels also use stable unique
   IDs so repeated replacement does not generate structural drift.
3. Read the dashboard back and verify its ID/title after the write.
4. Fail the apply script if data-view creation, dashboard replacement, or
   verification fails.

This avoids hand-editing saved-object internals and makes repeated deployment
converge to the repository state. The 9.4 Dashboards API is Technical Preview,
so the stack stays pinned to 9.4.3 and the static contract test guards the
endpoint, payload, stable IDs, panel hierarchy, and duplicate-exclusion rule.

The old hand-written NDJSON with an empty `panelsJSON` array is removed to
avoid two competing sources of truth.

## 7. Alternatives considered

### Import a modified saved-object NDJSON

Rejected. Elastic documents the import API for Kibana-exported NDJSON and
warns against changing exported saved-object data. It also exposes internal
saved-object structure and makes review of panel semantics difficult.

### Build every visualization manually in Kibana

Rejected as the deployment source of truth. It is useful for exploration but
not repeatable across hosts, and later manual drift is hard to detect.

### Store all audit logs in Wazuh and use only Wazuh dashboards

Rejected. Wazuh is strongest as the endpoint/host detection engine; the shared
ELK stream already correlates identity, access, Vault, proxy, and Wazuh events.
Moving every source to Wazuh would couple unrelated audit producers to one
detection product and reduce the existing unified investigation path.

## 8. Validation

Static validation must prove:

- JSON is syntactically valid.
- the fixed dashboard/data-view IDs and official PUT endpoint are wired.
- the canonical index exclusion appears in both data view and ES|QL queries.
- the five pinned controls exist.
- every section/control/panel ID is present and unique, every nested panel
  remains inside the 48-column grid, and panels do not overlap.
- the four KPIs, source trend, source freshness, high-signal table, behavioral
  pivots, and full timeline exist.
- the apply script treats failed writes or failed read-back as fatal.

When a live Kibana 9.4.3 endpoint is available, the same script performs the
actual API schema validation during deployment and verifies the persisted
dashboard by GET.
