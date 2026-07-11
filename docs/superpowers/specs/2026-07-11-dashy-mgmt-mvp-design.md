# Dashy Management MVP Design

## Goal

Deploy Dashy alongside the existing Homepage on the management host as a
Keycloak-protected infrastructure-operations shell.  The MVP must retain the
existing service index, provide a dedicated status page, and prove Dashy's
native Workspace view with one safe embedded application.  It must not become
a second monitoring collector or a privileged automation control plane.

## Current Context

- `home.${BASE_DOMAIN}` is an existing Homepage portal.  It remains online
  during the MVP.
- Traefik terminates HTTPS and has a reusable `sso-auth@file` ForwardAuth
  chain backed by OAuth2 Proxy and Keycloak realm `mgmt`.
- OAuth2 Proxy currently admits the `platform-admin` group, which makes the
  MVP an administrator-only console.
- Prometheus, Blackbox Exporter, node-exporter, Grafana, Alertmanager and Argo
  CD are already the sources of monitoring truth.  Dashy does not receive a
  Docker socket, kubeconfig, Vault token, or monitoring API credential.
- The default Traefik `secure-headers@file` middleware sets
  `X-Frame-Options: DENY` (`frameDeny: true`).  It remains the default for all
  services.

## Scope

### Included

1. A Dashy Compose stack at `dash.${BASE_DOMAIN}`, connected only to
   `mgmt-proxy` and protected by `sso-auth@file,secure-headers@file`.
2. Git-managed, read-only Dashy configuration with the configuration UI and
   local configuration saves disabled.
3. A Home page that migrates the existing Homepage service groups:
   Observability, Backup, CI/CD, Data, Infra, Security, and Edge.
4. A native `Status` sub-page linked from the Dashy header.  It contains a
   small, explicitly selected management-service card set with Dashy status
   dots and a direct Grafana link for detailed diagnosis.
5. Dashy's native Workspace view.  Grafana is the sole MVP item allowed to
   open in Workspace; high-privilege or unverified applications remain
   new-tab-only.
6. A narrow Grafana embedding policy: Grafana permits embedding and Traefik
   permits only `https://dash.${BASE_DOMAIN}` to frame the selected Grafana
   view.  The global `secure-headers` policy is not weakened.
7. Focused shell tests, Compose rendering checks, and live HTTP/header smoke
   tests on `acer-mgmt`.

### Excluded

- Replacing or deleting Homepage, changing `home.${BASE_DOMAIN}`, or changing
  DNS beyond adding the `dash` hostname where the current wildcard routing
  already covers it.
- Dashy widgets that query Prometheus, node-exporter, Blackbox Exporter, Argo
  CD, Vault, or any service API directly.
- Direct Docker/Kubernetes/Vault actions, arbitrary URLs, custom JavaScript,
  custom Dashy widgets, and a dropdown-driven custom iframe selector.
- Role-specific Dashy menus beyond the existing `platform-admin` admission.
- Embedding Vault, Teleport, Keycloak Admin, Traefik Dashboard, MinIO,
  GitLab, Harbor, Semaphore, or any other privileged service.

## Architecture

```text
Browser
  -> Traefik HTTPS
     -> OAuth2 Proxy ForwardAuth -> Keycloak (mgmt realm)
        -> Dashy: dash.<base-domain>
           |- Home: service index
           |- Status: bounded convenience probes + Grafana link
           `- Workspace: Grafana only

Prometheus / Blackbox / node-exporter -> Grafana -> detailed monitoring
```

Dashy is a presentation and navigation shell.  Prometheus remains responsible
for collection and alert evidence; Grafana remains responsible for time-series
queries and detailed dashboards.  Dashy status dots are explicitly convenience
availability probes, not the incident source of truth.

## User Experience

### Home

The Home page uses Dashy's standard grid view and preserves the existing
service taxonomy and URLs.  The default launch target is `newtab`, so an
operator continues to reach each application's normal authenticated UI.

Header navigation exposes:

- `Status` — Dashy local status sub-page.
- `Runbooks` — the existing documentation/runbook entry point.

Dashy's built-in view selector exposes Workspace; no custom hamburger menu or
dropdown is added.  This is intentional: Workspace already provides the
native left sidebar item selector and right iframe area.

### Status

Status contains only the management control-plane web endpoints selected for
the MVP: Grafana, Prometheus, Alertmanager, Argo CD, GitLab, NetBox, Vault,
and Dashy itself.  They use `statusCheck: true` and an interval of `0`, which
means a single check when the Status page is loaded and no continuous Dashy
polling.  Status links open Grafana in a new tab for detailed, historical
evidence.

This adds one browser-facing availability request per displayed item and page
load.  It does not scrape node-exporter or query Prometheus, and it does not
replace the existing Blackbox probes.

### Workspace

The first approved Workspace item is Grafana.  Selecting it opens Grafana in
Dashy's native sidebar-and-iframe view.  All other initial service cards either
open in a new tab or are hidden from Workspace.  Further services may join
only after a service-specific framing and login-flow review.

## Security Design

1. Dashy is behind the existing Traefik `sso-auth` chain.  Dashy's own auth,
   configuration editor, disk saves, local saves, API tokens, and proxy-based
   widgets are disabled for the MVP.
2. The Dashy config directory is mounted read-only.  Its container has no
   Docker socket, host root, secrets mount, kubeconfig, or service credentials.
3. `secure-headers@file` remains attached to Dashy and every normal service
   router.  A new `grafana-embed-headers@file` policy is attached only to a
   high-priority Grafana embed route and specifies a CSP `frame-ancestors`
   allowlist containing `https://dash.${BASE_DOMAIN}`.  It must not use
   `frameDeny: true`.
4. Grafana's `GF_SECURITY_ALLOW_EMBEDDING=true` is required for the approved
   embed route.  Grafana's existing Keycloak OIDC role mapping continues to
   govern its application permissions.
5. The embedding smoke test must prove that a non-Dashy origin is not allowed
   by the Grafana CSP.  If Keycloak's iframe login flow fails in a real browser,
   Grafana is changed back to new-tab-only and this MVP does not broaden the
   allowlist to repair it.

## Data and Failure Handling

- A failed Dashy status dot is an advisory signal.  The card offers the
  Grafana/Alertmanager route for evidence; it must not assert an outage.
- An iframe `Refused to connect` error is handled by the card's normal
  new-tab action.  No service is granted a framing exception merely to remove
  the error.
- Dashy failure affects only the new `dash` portal.  Homepage and all existing
  applications remain independently reachable.
- Rollback removes the Dashy stack and the Grafana-specific embed route and
  restores Grafana's previous embedding setting.  No monitoring data or
  service routing is removed.

## Verification

The implementation must provide evidence for all of the following:

1. A focused static test verifies the Dashy image, `dash.${BASE_DOMAIN}`
   router, `sso-auth@file,secure-headers@file`, read-only config mount,
   disabled config editing, the Home service groups, the Status page, and
   workspace/new-tab allowlist.
2. The existing Homepage configuration is unchanged and its service remains
   healthy after Dashy starts.
3. `docker compose config` renders the Dashy and Grafana changes without
   unresolved variables.
4. On `acer-mgmt`, the Dashy container is healthy and
   `https://dash.${BASE_DOMAIN}` redirects an unauthenticated request through
   the existing SSO path.
5. An authenticated browser test reaches Home, Status, and Workspace; Grafana
   is the only approved iframe target and the browser reports no framing error.
6. Grafana remains reachable directly and its standard UI retains the default
   anti-framing policy outside the narrowly scoped embed route.
