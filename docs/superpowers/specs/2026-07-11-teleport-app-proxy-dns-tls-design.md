# Teleport App Proxy DNS and TLS Design

## Goal

Make every configured Teleport application proxy URL under
`*.teleport.imcherry5778.xyz:3080` reachable from team clients without
redirecting existing Traefik-managed service hostnames.

## Root Cause

Teleport advertises seven application proxy addresses such as
`alertmanager.teleport.imcherry5778.xyz`.  The management DNS currently
rewrites only `teleport.imcherry5778.xyz` to the management Tailscale IP, so
the application hostnames do not resolve.  The current certificate contains
`*.imcherry5778.xyz`, which covers one hostname label only and does not cover
the additional `*.teleport.imcherry5778.xyz` level.

## Chosen Design

1. Add one AdGuard Home DNS rewrite for
   `*.teleport.imcherry5778.xyz` to the existing management Tailscale IP.
2. Issue and render a Teleport TLS certificate whose SANs include both
   `teleport.imcherry5778.xyz` and `*.teleport.imcherry5778.xyz`.
3. Keep the configured Teleport `public_addr` values unchanged.
4. Extend the repository DNS smoke script and shell test to require one
   representative application proxy hostname:
   `alertmanager.teleport.${BASE_DOMAIN}`.
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
   `alertmanager.teleport.${BASE_DOMAIN}` to the configured management
   Tailscale IP.
2. The Teleport certificate presented for the representative application
   hostname contains `DNS:*.teleport.${BASE_DOMAIN}`.
3. A TLS request to the representative application URL on port 3080 receives
   a Teleport response rather than a DNS or certificate-name error.
4. `tctl get app_server` still reports all seven configured applications.
5. The repository smoke test fails when the application-proxy hostname is not
   checked and passes once the required assertion is implemented.

## Rollback

Remove only the `*.teleport.${BASE_DOMAIN}` AdGuard rewrite and restore the
previous Teleport certificate version in the existing Vault render path.  The
base Teleport endpoint and all existing Traefik service DNS names remain
unchanged.
