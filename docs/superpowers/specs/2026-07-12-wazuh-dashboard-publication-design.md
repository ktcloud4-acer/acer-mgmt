# Wazuh Dashboard Publication Design

## Goal

Expose the existing Wazuh Dashboard at `wazuh.imcherry5778.xyz` and make it
discoverable from Dashy's Security section without exposing its loopback port.

## Architecture

`wazuh.imcherry5778.xyz` terminates TLS at Traefik, applies the existing
Keycloak-backed `sso-auth@file` middleware, and proxies over the private
`mgmt-proxy` Docker network to Wazuh Dashboard's HTTPS listener. Traefik uses
a dedicated transport that trusts the Dashboard's internal Wazuh certificate;
the browser never receives that certificate.

## Scope

- Add one dedicated Traefik dynamic file with the router, service, and HTTPS
  transport for Wazuh Dashboard.
- Add one Dashy Security item pointing at the canonical Wazuh URL.
- Add Keycloak groups `wazuh-admins` and `wazuh-readonly` for the later native
  Wazuh SAML/RBAC rollout.
- Keep Wazuh's current internal authentication active. Native SAML is a
  separate migration because it changes Indexer security configuration.

## Verification

- Static tests assert the canonical Dashy URL and Traefik router/service.
- Compose configuration validates.
- Runtime checks require an OAuth2 Proxy redirect at the public URL and a
  healthy Wazuh Dashboard behind Traefik.
