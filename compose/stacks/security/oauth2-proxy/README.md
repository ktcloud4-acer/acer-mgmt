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
