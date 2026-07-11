# Teleport App Proxy DNS and TLS Design

## Goal

Make every configured Teleport application proxy URL under
`tp-*.imcherry5778.xyz:3080` reachable from team clients without
redirecting existing Traefik-managed service hostnames.

## Root Cause

Teleport advertises seven application proxy addresses such as
`alertmanager.teleport.imcherry5778.xyz`.  The management DNS currently
rewrites only `teleport.imcherry5778.xyz` to the management Tailscale IP, so
the application hostnames do not resolve.  The current certificate contains
`*.imcherry5778.xyz`, which covers one hostname label only and does not cover
the additional nested application hostname level.

## Chosen Design

1. Set each Teleport application's explicit `public_addr` to a unique
   `tp-<app>.imcherry5778.xyz` hostname covered by the existing wildcard
   certificate.
2. Add exact AdGuard Home rewrites for those seven hostnames to the existing
   management Tailscale IP.
3. Keep the existing Teleport TLS certificate and base proxy address unchanged.
4. Extend the repository DNS smoke script and shell test to require one
   representative application proxy hostname:
  `tp-alertmanager.${BASE_DOMAIN}`.
5. Verify DNS resolution, the certificate name, Teleport's HTTP response, and
   the registered application proxy resources from a real client path.

## Security Constraints

- Do not add a broad `*.imcherry5778.xyz` rewrite: that would hijack existing
  Traefik service hostnames.
- Do not use an insecure browser exception or disable TLS validation.
- Do not place certificate private keys, Vault values, or AdGuard credentials
  in Git, command output, or documentation.
- Retain Teleport's existing Tailscale-only listener on port 3080 and its
  application labels and roles.

## Acceptance Criteria

1. AdGuard resolves both `teleport.${BASE_DOMAIN}` and
   `tp-alertmanager.${BASE_DOMAIN}` to the configured management
   Tailscale IP.
2. The existing Teleport certificate presented for the representative
   application hostname matches `*.${BASE_DOMAIN}`.
3. A TLS request to the representative application URL on port 3080 receives
   a Teleport response rather than a DNS or certificate-name error.
4. `tctl get app_server` still reports all seven configured applications.
5. The repository smoke test fails when the application-proxy hostname is not
   checked and passes once the required assertion is implemented.

## Rollback

Remove only the seven `tp-<app>.${BASE_DOMAIN}` AdGuard rewrites and restore
the previous Teleport application `public_addr` values.  The base Teleport
endpoint, certificate, and all existing Traefik service DNS names remain
unchanged.
