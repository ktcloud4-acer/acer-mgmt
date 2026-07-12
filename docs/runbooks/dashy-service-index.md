# Dashy Service Index Deployment

Dashy is a Keycloak-protected service index deployed alongside Homepage. It
does not collect monitoring data. The current **demo mode** permits iframe
views globally through Traefik, removes backend `X-Frame-Options` headers, and
enables Grafana embedding, so Dashy's modal and Workspace opening methods can
be demonstrated. This is not a production security profile; restore
`frameDeny: true`, remove the `X-Frame-Options` response override, and remove
`GF_SECURITY_ALLOW_EMBEDDING` before production exposure.

The shared oauth2-proxy session protects the browser-only UI routes for
Grafana, Prometheus, Alertmanager, Kibana, MinIO Console, Allure, Playwright,
Semaphore, Kafka UI, AdGuard Home, Traefik, Vault, Homepage, and Dashy.
Vault `/v1/*`, MinIO S3, Supabase APIs, Teleport, and service APIs used by
automation retain their native authentication flows.

The shared browser gateway requires the Keycloak group
`${OAUTH2_PROXY_ALLOWED_GROUP:-platform-admin}`. The `/oauth2/*` callback
keeps the signed return URL and sends a successful login back to the requested
service. Application-native permissions still apply after the gateway.

Grafana additionally uses Auth Proxy and accepts the user header only from
Traefik's fixed `/32` address on the isolated `traefik-grafana-auth` Docker
network. Create the two required isolated networks before starting Traefik,
Grafana, or Prometheus:

```bash
bash compose/scripts/reconcile-dashy-sso-networks.sh
```

Allure `:5050` and Playwright `:8099` remain Tailnet-bound machine upload
compatibility endpoints. They serve the same applications as the browser UI,
so operators must use the SSO-protected HTTPS hostnames for browser access;
do not treat those machine endpoints as an authentication boundary.

Run `bash compose/tests/test-dashy-service-index.sh` from the repository root
before deployment.

## Deploy

From `/home/user1/acer-mgmt/compose`, first render the stack and then start it:

```bash
docker compose --env-file ../.env \
  -f stacks/edge/dashy/compose.yaml config >/dev/null
docker compose --env-file ../.env \
  -f stacks/edge/dashy/compose.yaml up -d
docker ps --format '{{.Names}} {{.Status}}' | grep '^dashy '
```

The `dashy` container must report `healthy`.

## Verify

```bash
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://dash.imcherry5778.xyz
curl -sS -o /dev/null -w '%{http_code}\n' https://home.imcherry5778.xyz
```

Unauthenticated Dashy access must use the existing SSO flow. Homepage must
remain reachable.

After signing in as `platform-admin`, verify the seven service groups and that
a normal left-click opens a service in a new tab. Dashy's built-in right-click
context menu remains enabled so operators can choose another supported opening
method, including modal or Workspace. Grafana must render in both iframe modes.

Vault is split at Traefik: its UI uses the shared oauth2-proxy session, while
`/v1/*` retains Vault-token authentication. To reconcile the Vault UI CSP and
remove only the explicit legacy `dashy-embed-ui-headers` policy, first create the management token
inside the Vault container and then run:

```bash
docker exec -it vault sh -c 'vault login -method=userpass -token-only username=mgmt > /tmp/.vt'
bash compose/scripts/reconcile-vault-dashy-embed.sh
```

The script does not print or copy the token. It requires a Vault token that
can write `sys/config/ui/headers/Content-Security-Policy` with `sudo`.

## Rollback

```bash
cd /home/user1/acer-mgmt/compose
docker compose --env-file ../.env \
  -f stacks/edge/dashy/compose.yaml down
```

Homepage and all existing service routes are independent of Dashy and remain
available.
