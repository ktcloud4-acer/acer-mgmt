# Semaphore Ansible playbooks

Semaphore task templates execute only playbooks in this directory. Playbooks use
localhost unless a task explicitly needs a team AIO inventory. Secrets are read
at runtime from a Semaphore Variable Group or a mounted Vault-rendered file;
do not commit credentials or wrapper shell scripts here.

- dns-smoke-test.yml validates mgmt DNS through AdGuard.
- run-scalecart-api-hpa-load-test.yml runs the team-scoped k6 workload.
- issue playbooks issue Chaos Dashboard tokens.
