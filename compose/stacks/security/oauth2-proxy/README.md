# OAuth2 Proxy SSO gateway

`oauth2-proxy` is the shared forward-auth service used by Traefik middleware
`sso-auth@file`. Services such as Homepage call Traefik, Traefik calls
`http://oauth2-proxy:4180/oauth2/auth`, and unauthenticated users are redirected
to Keycloak.

Runtime secrets are rendered by Vault Agent from `kv/mgmt/oauth2-proxy`:

- `client_secret` -> `/home/mgmt-data/vault-agent/secrets/oauth2_proxy_client_secret`
- `cookie_secret` -> `/home/mgmt-data/vault-agent/secrets/oauth2_proxy_cookie_secret`

The proxy is intentionally attached only to the internal `mgmt-proxy` network.
The public entrypoint is `https://auth.${BASE_DOMAIN}` through Traefik.

## Session lifetime

Keycloak's SSO idle timeout is reconciled to one hour by the bootstrap script.
oauth2-proxy refreshes an active browser session every 30 minutes and retains
its browser cookie for up to eight hours. Session tokens are stored in the
private `oauth2-proxy-redis` container, so the browser receives only a small
session key instead of a multi-part token cookie. An inactive session therefore
needs to sign in again after one hour, while an actively used dashboard refreshes
before Keycloak expires its refresh token.

## RedisInsight administration

`https://redis.${BASE_DOMAIN}` routes to RedisInsight, not to Redis TCP. It is
protected by the existing Keycloak-backed `sso-auth@file` middleware, so only
the configured `platform-admin` group can reach it. Redis itself has no
published port and is reachable only through the internal
`oauth2-proxy-session` Docker network. In RedisInsight, add
`oauth2-proxy-redis:6379`; do not expose that port or reuse an
application-specific Redis/Valkey instance.

## Browser access model

The shared browser gateway requires membership in
`${OAUTH2_PROXY_ALLOWED_GROUP:-platform-admin}`. Application-native
authorization remains responsible for sensitive operations after this shared
gate. The `/oauth2/*` paths are oauth2-proxy callback endpoints, so a login
initiated for Vault, Grafana, or another service returns to that service.

Before enabling the group gate in a new or rebuilt realm, reconcile the
oauth2-proxy client and its `groups` mapper. The script reads the client secret
only from the Vault Agent render file. Run the same command after deploying a
change to this gateway; it also applies the one-hour SSO idle timeout:

```bash
set -a
. /home/mgmt-data/vault-agent/secrets/security/keycloak.env
set +a
BASE_DOMAIN=imcherry5778.xyz \
  bash compose/scripts/keycloak-oauth2-proxy-bootstrap.sh
```
