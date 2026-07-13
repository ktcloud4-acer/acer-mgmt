# Audit Access Normalization Design

## Goal

Turn proxy and identity container output into investigation-ready audit events
instead of marking every container line as an audit event. The dashboard must
separate access, identity/privileged, host-security, and high-signal workflows
so source-specific optional fields do not appear as meaningless null columns.

## Current problem

- Filebeat writes static root field `user: mgmt`; the dashboard presents the
  collection team as though it were a human actor.
- Every Traefik, oauth2-proxy, and Keycloak stdout line receives
  `labels.audit_source`, including stack traces and startup messages.
- HTTP method, path, status, client IP, request ID, and Keycloak actor data stay
  embedded in `message`.
- The mixed full-timeline table asks every source for the same detailed fields,
  producing large runs of `(null)`.
- Existing indices map root `user` as text. They cannot accept ECS object
  `user.name` without a new index generation.

## Approaches considered

1. **Dashboard-only cleanup:** Hide null columns and relabel `user`. This is
   low-risk but leaves the data unusable for filters and investigation.
2. **Compatible ingestion normalization (selected):** Parse the current text
   formats, add explicitly mapped HTTP and actor fields, and reorganize the
   dashboard. This gives immediate value without rewriting history.
3. **New ECS v2 audit index:** Roll over to a new index family with `user.name`
   and fully structured producer logging. This is the long-term ideal but needs
   coordinated service restarts, migration, retention, and cross-index design.

## Field contract

`labels.team=mgmt` remains the ownership/tenant field. Static root `user=mgmt`
is removed from the mgmt Filebeat inputs. Real actors use a compatible custom
object until an ECS v2 migration is scheduled:

| Meaning | Field | Mapping |
|---|---|---|
| Human/service actor display name | `actor.name` | `keyword` |
| Stable actor ID | `actor.id` | `keyword` |
| Collector before host normalization | `observer.name` | `keyword` |
| Client address | `source.ip` | `ip` |
| Request ID | `trace.id` | `keyword` |
| HTTP method | `http.request.method` | `keyword` |
| HTTP status | `http.response.status_code` | `integer` |
| Response bytes | `http.response.body.bytes` | `long` |
| Request host | `url.domain` | `keyword` |
| Full request target | `url.original` | `wildcard` |
| Request path | `url.path` | `text` plus `keyword` |
| Query string | `url.query` | `wildcard` |
| Browser/client agent | `user_agent.original` | `wildcard` |
| Normalized result | `event.outcome` | `keyword` |
| Event category | `event.category` | `keyword` |

The same mapping body is installed for future indices through the audit index
template and added idempotently to existing audit indices before Kibana objects
are provisioned.

## Source normalization

### Traefik

Only standard access lines matching the observed combined format become
canonical audit events. The parser extracts client IP, method, path/query,
HTTP version/status/bytes, referrer, user agent, router/backend information,
and access timestamp. `event.action=http-request`; status below 400 is success,
otherwise failure. Stack traces and service logs remain ordinary Docker logs.

### oauth2-proxy

Only request log lines become canonical audit events. The parser extracts
client IP, request ID, optional authenticated actor, request domain, method,
path/query, HTTP version/status/bytes, user agent, and timestamp.
`/oauth2/auth` uses `event.action=authentication`; other paths use
`event.action=http-request`. Status below 400 is success, otherwise failure.

### Keycloak

Only `org.keycloak.events` lines become canonical audit events. The prefix and
comma-delimited key/value payload are parsed. `type` becomes `event.action`,
`username`/`userId` become `actor.name`/`actor.id`, and `ipAddress` becomes
`source.ip`. Event types ending in `_ERROR` are failures; other event types are
successes. Other Keycloak service logs remain ordinary Docker logs.

### Vault, Teleport, and Wazuh

Existing normalization remains. Vault and Teleport identities are copied to
`actor.name`; Wazuh keeps the endpoint in `host.name` while the collection host
is retained as `observer.name`.

## Detection scope

Existing Vault and Wazuh high-signal rules remain authoritative. Individual
oauth2-proxy 401 responses are not stamped as alerts because synthetic probes
intentionally generate them. Authentication failures are aggregated on the
dashboard. Stateful burst detection is explicitly out of scope for this
single-event Logstash filter change.

## Dashboard design

The stable dashboard ID remains `security-audit-overview`. All queries exclude
alert-routing copies and ignore historical proxy/Keycloak documents that lack
normalized `event.action`.

1. **Current situation:** four KPIs for canonical volume, high signal, Wazuh,
   and active sources.
2. **Trend and collection coverage:** volume trend, source distribution, and
   freshness.
3. **Immediate investigation:** high-signal events only, so alert signature is
   always meaningful.
4. **Access and authentication:** recent proxy access, authentication failures,
   and top requested paths.
5. **Security domains:** identity/privileged events beside Wazuh host security.
6. **Full audit timeline:** only common fields—time, source, service, actor,
   host, action, outcome, and message.

Pinned controls become source, team, alert signature, actor, and host. Actor
uses `actor.name`, not the legacy root `user` field.

## Rollout and verification

- No update-by-query, reindex, or deletion is performed.
- Static contract tests cover the mapping, parser gates, removal of static
  `user: mgmt`, field names, dashboard sections, queries, and layout.
- Logstash configuration syntax is checked before restart.
- After deployment, fresh source events must populate HTTP/actor fields while
  non-access container lines stop entering the audit index.
- Elasticsearch field caps, representative ES|QL queries, Kibana saved state,
  and container health are verified before completion.

## Non-goals

- Backfilling historical proxy and identity events.
- Replacing Wazuh or adding a second detection engine.
- Stateful rate/burst detection.
- Migrating the entire audit index to ECS `user.name` in this change.
