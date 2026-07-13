# Dashy Chaos Health Probe Fix Design

## Problem

Dashy checks each Chaos Mesh card through `platform-monitor`. The monitor still
probes retired `<team>-chaos.tailc0244b.ts.net` MagicDNS names, while the
management Traefik routes have moved to `<team>-ingress.tailc0244b.ts.net`.
The retired names do not resolve, so the monitor returns HTTP 503 even when the
team ingress and Chaos Dashboard are reachable.

## Decision

Keep Dashy's internal status API unchanged. Update `CHAOS_UPSTREAMS` so every
team probe connects to its existing `<team>-ingress` Tailscale HTTPS endpoint
and sends `Host: <team>-chaos.imcherry5778.xyz`. TLS therefore uses the valid
ingress MagicDNS name, while the HTTP Host header selects the Chaos Dashboard
router on the spoke Traefik.

Probing the public management URL was rejected because it would mix service
health with SSO behavior. Parsing Traefik configuration at runtime was rejected
because it adds coupling and file-mount requirements to a small monitor.

## Scope

- Change the five team entries in `platform-monitor/app/server.py`.
- Add a regression test for the complete URL and Host-header mapping.
- Correct the stale static Traefik test to require `<team>-ingress` and
  `passHostHeader: true`.
- Do not change Dashy card URLs, status API URLs, SSO, SSH, or DNS records.

## Verification

Local tests must prove the mapping, status behavior, Dashy configuration, and
Traefik route expectations. After the repository-required commit, push, merge,
and runtime-sync approvals, runtime verification must rebuild only
`platform-monitor`, then confirm ggg and nmg return HTTP 200 with `healthy:
true`. Other team cards must continue to reflect their real ingress state; a
team without an active `<team>-ingress` device must remain unhealthy.
