# Dashy Open-Access SSO Design

## Goal

Make Keycloak authentication, rather than Keycloak group membership, the
single shared browser entry requirement for Dashy and the UI routes protected
by oauth2-proxy. A successful login must return the user to the requested
service and must not leave them on oauth2-proxy's `Authenticated` page.

## Scope

- Remove oauth2-proxy's `--allowed-group` gate. Any authenticated user in the
  `mgmt` Keycloak realm can pass the shared browser gateway.
- Keep Keycloak as the identity provider, the existing cookie domain, and the
  `X-Auth-Request-*` headers forwarded by Traefik.
- Add an exact `auth.<BASE_DOMAIN>/` Traefik router with higher priority than
  the catch-all oauth2-proxy router. It redirects only the auth-host root to
  `https://dash.<BASE_DOMAIN>/`.
- Preserve `auth.<BASE_DOMAIN>/oauth2/*` unchanged. In particular, the
  callback continues to honor its signed `rd` value, so a Vault or Grafana
  login returns to that service rather than Dashy.
- Preserve native non-browser authentication boundaries: Vault `/v1/*`,
  MinIO S3, Supabase APIs, Teleport, and service-specific sessions are not
  opened by this change.

## Security Trade-off

This is deliberately a demo/simple-access profile. Every account that can
authenticate to the `mgmt` Keycloak realm can reach oauth2-proxy-protected UI
routes. Grafana Auth Proxy will auto-provision those users with Grafana's
default Viewer role. Application-native permissions remain active where the
application has them. Reintroducing group or role authorization is a later,
separate hardening change.

## Error Handling

Group-denial 403s disappear because oauth2-proxy no longer performs a group
comparison. A genuine OIDC failure (invalid callback state, expired code, or
provider outage) remains an oauth2-proxy error rather than being redirected,
so operators do not lose a diagnosable authentication failure.

## Verification

Static tests must prove that the group flag is absent and that the exact-root
router/redirect cannot capture `/oauth2/*`. Runtime checks must show:

1. an unauthenticated Vault UI request redirects to Keycloak;
2. `auth.<BASE_DOMAIN>/` redirects to Dashy;
3. `auth.<BASE_DOMAIN>/oauth2/callback` remains served by oauth2-proxy; and
4. Vault `/v1/sys/health` still bypasses the browser gateway.
