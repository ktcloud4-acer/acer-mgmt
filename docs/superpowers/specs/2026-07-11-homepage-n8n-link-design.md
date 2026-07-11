# Homepage n8n Link Design

## Goal

Expose the deployed n8n service in the ACER management Homepage so operators can reach its SSO-protected UI from the existing Observability group.

## Scope

- Add one `n8n` Homepage card under `Observability`.
- Use the deployed public hostname pattern: `https://n8n.{{HOMEPAGE_VAR_BASE_DOMAIN}}`.
- Describe the card as the platform operations-digest automation UI.
- Add a focused shell regression test that asserts the card name, URL template, and description.

## Constraints

- Do not expose a port, add credentials, or change n8n, Traefik, or SSO configuration.
- Preserve the existing Homepage YAML card format and variable substitution convention.
- The card remains protected by the existing Homepage and n8n SSO routing.

## Verification

Run the focused Homepage test and the existing n8n stack/workflow tests. On mgmt, render the Homepage Compose file and confirm Homepage stays healthy after the configuration bind mount updates.
