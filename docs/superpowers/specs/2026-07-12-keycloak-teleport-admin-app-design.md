# Keycloak Teleport Admin App Design

## Goal

Expose the Keycloak administration console as a supplemental Teleport
Application resource without changing the canonical Keycloak OIDC issuer used
by oauth2-proxy and other platform clients.

## Architecture

Teleport proxies `keycloak-admin.teleport.imcherry5778.xyz:3080` to
`http://keycloak:8080` on the private `mgmt-proxy` network. Keycloak remains
available at `https://keycloak.imcherry5778.xyz`; that hostname remains the
only issuer and client redirect authority.

The Teleport app rewrites redirects originating at the canonical Keycloak
hostname back to its own application address. Keycloak's existing
`KC_HOSTNAME_STRICT=false` and `KC_PROXY_HEADERS=xforwarded` settings allow
the supplemental proxy host without replacing the issuer hostname.

## Scope

- Add one static `keycloak-admin` entry under `app_service.apps`.
- Add the matching exact AdGuard rewrite.
- Add static tests for the app contract and DNS reconciliation list.
- Restart only the Teleport application service and AdGuard DNS after
  configuration validation.

## Constraints

- Do not alter `KC_HOSTNAME`, `KC_HOSTNAME_ADMIN`, realm issuer URLs, or
  oauth2-proxy client configuration.
- Do not remove the direct Keycloak browser entry point.
- Do not add a custom icon URL: Teleport Community Application resources do
  not expose one. The stock UI may choose a built-in icon based on app name.
- Keep labels `env: mgmt` and `owner: security` for RBAC filtering.

## Validation

- Static test asserts the URI, Teleport public address, canonical redirect
  rewrite, labels, and DNS entry.
- Compose rendering validates the Teleport stack.
- HTTPS to the new application hostname reaches Teleport, and the direct
  Keycloak hostname continues to respond.
