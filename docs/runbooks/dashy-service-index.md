# Dashy Service Index Deployment

Dashy is a Keycloak-protected service index deployed alongside Homepage. It
does not collect monitoring data. The current **demo mode** permits iframe
views globally through Traefik, removes backend `X-Frame-Options` headers, and
enables Grafana embedding, so Dashy's modal and Workspace opening methods can
be demonstrated. This is not a production security profile; restore
`frameDeny: true`, remove the `X-Frame-Options` response override, and remove
`GF_SECURITY_ALLOW_EMBEDDING` before production exposure.

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

## Rollback

```bash
cd /home/user1/acer-mgmt/compose
docker compose --env-file ../.env \
  -f stacks/edge/dashy/compose.yaml down
```

Homepage and all existing service routes are independent of Dashy and remain
available.
