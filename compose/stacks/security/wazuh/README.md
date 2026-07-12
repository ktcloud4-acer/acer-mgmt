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
healthy and their enrollment key has been stored in Vault.

Apply shared FIM group configs with `compose/scripts/apply-wazuh-agent-groups.sh`
so secret paths stay outside file-integrity monitoring. It pushes two groups:

- `default` ← `config/agent.conf` — acer-mgmt / acer-aio hosts (Vault, Kolla,
  SSH, kubeconfig, tfstate, backups).
- `k8s-nodes` ← `config/agent.conf.k8s-nodes` — kubeadm master/worker nodes; adds
  Kubernetes control-plane secrets (`/etc/kubernetes/pki`, `*.conf`, `/var/lib/etcd`,
  kubelet mounted secrets). k8s node agents enroll with `WAZUH_AGENT_GROUP=k8s-nodes`
  (see `acer-aio/30-k8s-kubeadm`), so this file is standalone/self-contained.
