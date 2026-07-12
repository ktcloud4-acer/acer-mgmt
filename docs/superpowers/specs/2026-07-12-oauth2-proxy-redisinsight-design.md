# OAuth2 Proxy Redis Session and RedisInsight Design

## Goal

Move shared OAuth2 Proxy sessions out of browser cookies and expose a protected
RedisInsight console at `https://redis.imcherry5778.xyz`.

## Problem

The Keycloak access, ID, refresh, and group claims exceed the browser's 4 KiB
cookie limit. OAuth2 Proxy splits this state over multiple cookies. Concurrent
browser requests can then refresh the same Keycloak refresh token and invalidate
the session, causing a `401 -> sign-in` redirect loop.

## Design

The OAuth2 Proxy Compose stack owns three containers:

- `oauth2-proxy-redis`: a private, persistent Redis instance storing sessions.
- `oauth2-proxy`: uses Redis session storage and keeps only a small session key
  in the browser cookie.
- `redisinsight`: a persistent management UI connected to the private Redis
  network and published only through Traefik forward authentication.

`oauth2-proxy-redis` joins only the internal `oauth2-proxy-session` network.
It has no published ports and no Traefik labels. `oauth2-proxy` and
`redisinsight` join that network; RedisInsight additionally joins `mgmt-proxy`
for Traefik. The `redis` hostname routes only to RedisInsight and uses the
existing `sso-auth@file` middleware, which is restricted to `platform-admin`.

## Operations

Redis data and RedisInsight metadata use named Docker volumes. Deploying the
stack invalidates existing OAuth2 Proxy browser sessions once; users sign in
again through Keycloak. The DNS reconciliation script adds an AdGuard rewrite
for `redis.${BASE_DOMAIN}`; the public exact DNS record remains an edge-DNS
runtime responsibility, as credentials are not stored in Git.

