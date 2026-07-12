# Dashy SSO and Vault Embed Design

## Goal

Use Keycloak as the single identity provider and oauth2-proxy as the common
Traefik UI gate, while preserving service APIs and native access planes.

## Boundaries

- Keycloak remains directly reachable as the identity provider and its login
  response may be framed only by `https://dash.imcherry5778.xyz` in demo mode.
- OAuth2-proxy is the authoritative public browser gate for the selected UI
  routes and emits authenticated user/group headers. Grafana consumes the
  user header through Grafana Auth Proxy, so it does not initiate a second
  login. Applications without a compatible auth-proxy mode remain additionally
  protected by their native session rather than having their native security
  disabled.
- OAuth2-proxy is not applied to Vault `/v1/*`, MinIO S3, Supabase APIs, or
  Teleport. Direct Teleport application access and CLI access remain available
  as a separate access plane; selected browser UI routes intentionally use the
  common oauth2-proxy entry instead of a Teleport redirect.
- Vault has two explicit routers: the UI uses `sso-auth`; `/v1/*` bypasses the
  browser gate and retains Vault token authentication.
- Dashy keeps new-tab as its global default. Grafana, Alertmanager, Semaphore,
  and Vault opt into Workspace as their default opening target.
- Prometheus and Alertmanager no longer publish host UI ports. Allure retains
  a Tailnet-bound `5050` listener solely for CI result-upload compatibility;
  its browser UI is the Traefik/oauth2-proxy route.
- Playwright `:8099` is likewise a Tailnet CI upload compatibility endpoint,
  not an authenticated browser endpoint. AdGuard's browser UI no longer has a
  direct host-port listener.
- Grafana accepts oauth2-proxy identity headers only from Traefik's fixed
  address on an isolated Docker network. Its Prometheus data-source traffic
  uses a second isolated network.

## Vault resource ownership

The reconciliation script creates or updates the Vault UI CSP header and adds
only that endpoint to the existing `admin` policy. It never deletes an
unrecognised auth mount, policy, or secret path. The sole legacy policy it may
delete is the explicitly named `dashy-embed-ui-headers` policy.

## Verification

Static tests cover router separation, Keycloak framing headers, Dashy targets,
and the Vault reconciliation contract. Runtime checks prove the rendered
Traefik configuration, Vault UI/API routing, and iframe response headers.
