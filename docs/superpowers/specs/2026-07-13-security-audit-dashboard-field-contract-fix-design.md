# Security Audit Dashboard Field Contract Fix Design

## Problem

The live `acer-audit-*` indices store the normalized actor as scalar `user`
with an aggregatable `user.keyword` multi-field. The dashboard instead uses
`user.name.keyword`, so the User control errors and Top users is empty.

High-signal events stamp `labels.audit_alert`, but no live event has yet created
that dynamic field. The Alert signature control asks Kibana for
`labels.audit_alert.keyword`, so the control errors when the field is absent.

The Wazuh KPI counts every canonical Wazuh audit event, not only Wazuh events
that crossed the high-signal threshold, so its current title is misleading.

## Chosen design

Keep the current index contract and make the dashboard follow it:

- Use `user.keyword` for the User options control and Top users aggregation.
- Display scalar `user` in the high-signal and full-timeline tables.
- Map `labels.audit_alert` explicitly as `keyword` in the `acer-audit` index
  template, apply the same additive mapping to existing `acer-audit-*` indices,
  and point the control directly at `labels.audit_alert`.
- Rename the KPI to `Wazuh audit events` and describe it as all normalized
  Wazuh events.

No audit documents are rewritten or backfilled. A zero high-signal result
remains an honest zero until a detector stamps a new event.

## Deployment and safety

`apply-observability.sh` installs the template first, adds the mapping to
existing indices, recreates the stable `acer-audit` data view, and then replaces
the stable dashboard. The mapping change is additive and idempotent.

Tests enforce the control fields, actor queries/table columns, KPI wording, and
the explicit Elasticsearch mapping. Live verification checks field caps,
dashboard retrieval, representative ES|QL results, and container health.
