# Semaphore Ansible playbooks

Semaphore task templates execute only playbooks in this directory. Playbooks use
localhost unless a task explicitly needs a team AIO inventory. Secrets are read
at runtime from a Semaphore Variable Group or a mounted Vault-rendered file;
do not commit credentials or wrapper shell scripts here.

- dns-smoke-test.yml validates mgmt DNS through AdGuard.
- run-scalecart-api-hpa-load-test.yml runs the team-scoped k6 workload.
- issue playbooks issue Chaos Dashboard tokens.
- `../scripts/bootstrap-teleport-team-nodes.sh <team>` is the root-only central
  Teleport enrollment bootstrap. It creates four short-lived node tokens,
  streams them to the selected AIO, runs layer-25, verifies the registered
  native nodes, then revokes and removes every token. Run it only on
  `acer-mgmt`; it never grants `tctl` authority to an AIO.
