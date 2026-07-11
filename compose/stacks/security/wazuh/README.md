# Wazuh central stack

This is a separate Wazuh manager, Wazuh indexer, and Wazuh dashboard stack. It
does not reuse Elasticsearch/Kibana: Filebeat sends only `alerts.json` to the
existing audit pipeline for correlation.

Before first start, Vault Agent must render
`/run/acer-mgmt/secrets/security/wazuh.env` with distinct values for:

- `WAZUH_INDEXER_PASSWORD`
- `WAZUH_DASHBOARD_PASSWORD`
- `WAZUH_API_PASSWORD`

Run `compose/scripts/bootstrap-wazuh-stack.sh`, then start the compose stack
with that same env file. The dashboard is loopback-only until Teleport app TLS
has been provisioned; do not add a public Traefik route.

Deploy native agents on `acer-mgmt` and `acer-aio` only after the manager is
healthy and their enrollment key has been stored in Vault. Apply `agent.conf`
to the agent group so secret paths remain outside file-integrity monitoring.
