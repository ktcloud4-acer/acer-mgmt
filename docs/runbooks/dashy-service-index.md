# Dashy Service Index Deployment

Dashy is a Keycloak-protected service index deployed alongside Homepage.  It
does not collect monitoring data, embed privileged services, or change Grafana.

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
method, including modal or Workspace.

## Rollback

```bash
cd /home/user1/acer-mgmt/compose
docker compose --env-file ../.env \
  -f stacks/edge/dashy/compose.yaml down
```

Homepage and all existing service routes are independent of Dashy and remain
available.
