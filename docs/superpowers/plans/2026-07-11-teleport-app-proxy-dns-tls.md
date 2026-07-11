# Teleport App Proxy DNS and TLS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore browser access to Teleport application proxy URLs by adding the required DNS and certificate coverage without changing existing Traefik hosts.

**Architecture:** AdGuard Home resolves only the nested Teleport application namespace to the existing management Tailscale IP.  Vault continues to render the Teleport certificate, but that certificate is reissued with the matching nested wildcard SAN.  A repository smoke test protects the DNS expectation and remote probes confirm the full browser transport path.

**Tech Stack:** Bash, AdGuard Home DNS rewrites, Vault PKI, Teleport 18.9.2, OpenSSL, GitLab CI-compatible shell tests.

## Global Constraints

- Keep all existing `*.imcherry5778.xyz` Traefik hostnames unchanged.
- Add only `*.teleport.imcherry5778.xyz` DNS coverage for Teleport app proxies.
- Do not store secret values, private keys, or API tokens in Git.
- Verify a real client DNS lookup, TLS SAN, Teleport HTTP response, and live app registration.

---

### Task 1: Protect the application-proxy DNS contract

**Files:**
- Modify: `compose/scripts/dns-smoke-test.sh`
- Modify: `compose/tests/test-dns-smoke-test.sh`

**Interfaces:**
- Consumes: `BASE_DOMAIN`, `ADGUARD_DNS_IP`, and `EXPECTED_IP` environment variables.
- Produces: a required `alertmanager.teleport.${BASE_DOMAIN}` DNS assertion in the smoke script.

- [ ] **Step 1: Write the failing test**

Add the representative nested hostname to the test fake resolver's successful
case and assert its `OK` line:

```bash
alertmanager.teleport.imcherry5778.xyz)
  echo "${EXPECTED_IP:-100.117.59.96}"
  ;;
```

```bash
assert_contains "$stdout" "OK   alertmanager.teleport.imcherry5778.xyz -> 100.117.59.96"
```

- [ ] **Step 2: Run the test to verify RED**

Run: `bash compose/tests/test-dns-smoke-test.sh`

Expected: FAIL because `dns-smoke-test.sh` does not yet query the nested
application-proxy hostname.

- [ ] **Step 3: Write the minimal implementation**

Add this line after the base Teleport service assertion in
`compose/scripts/dns-smoke-test.sh`:

```bash
assert_adguard_answer "alertmanager.teleport.${BASE_DOMAIN}"
```

- [ ] **Step 4: Run the test to verify GREEN**

Run: `bash compose/tests/test-dns-smoke-test.sh`

Expected: `dns-smoke-test tests passed`.

### Task 2: Apply the live DNS and certificate prerequisites

**Files:**
- Modify: AdGuard Home runtime rewrite state (not stored in Git).
- Modify: Vault PKI certificate issuance input/runtime secret render (not stored in Git).

**Interfaces:**
- Consumes: management Tailscale IP `100.117.59.96` and the existing Teleport
  certificate render path `/run/acer-mgmt/secrets/security/teleport/tls.crt`.
- Produces: DNS A answer and a certificate SAN for
  `*.teleport.imcherry5778.xyz`.

- [ ] **Step 1: Verify the failing runtime probes**

```bash
getent ahostsv4 alertmanager.teleport.imcherry5778.xyz
printf '' | openssl s_client -connect 100.117.59.96:3080 \
  -servername alertmanager.teleport.imcherry5778.xyz 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName
```

Expected: DNS has no address and the certificate has no nested wildcard SAN.

- [ ] **Step 2: Apply the minimum runtime changes**

Create the AdGuard rewrite `*.teleport.imcherry5778.xyz -> 100.117.59.96`.
Reissue the existing Vault-rendered Teleport certificate with
`teleport.imcherry5778.xyz` and `*.teleport.imcherry5778.xyz`, then restart
only the Teleport container to load the rendered certificate.

- [ ] **Step 3: Verify live transport**

```bash
getent ahostsv4 alertmanager.teleport.imcherry5778.xyz
printf '' | openssl s_client -connect 100.117.59.96:3080 \
  -servername alertmanager.teleport.imcherry5778.xyz 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName
curl -k -I --connect-timeout 10 \
  https://alertmanager.teleport.imcherry5778.xyz:3080/
```

Expected: DNS returns `100.117.59.96`, SAN contains the nested wildcard, and
Teleport responds with a redirect or authentication response.

### Task 3: Verify application availability and document recovery

**Files:**
- Modify: `compose/stacks/security/teleport/README.md`

**Interfaces:**
- Consumes: the nested wildcard DNS and certificate contract from Tasks 1-2.
- Produces: recovery guidance that names both requirements without exposing
  credential material.

- [ ] **Step 1: Add the recovery contract**

Document that application proxy hosts use
`<app>.teleport.${BASE_DOMAIN}:3080`, require an AdGuard nested wildcard
rewrite, and require a certificate SAN for `*.teleport.${BASE_DOMAIN}`.

- [ ] **Step 2: Verify repository and runtime state**

Run:

```bash
bash compose/tests/test-dns-smoke-test.sh
DNS_SMOKE_REQUIRE_DIRECT=true bash compose/scripts/dns-smoke-test.sh
ssh acer-mgmt 'sudo -n docker exec teleport tctl get app_server --format=json | jq length'
```

Expected: shell test passes, direct DNS smoke test passes, and app server count
is `7`.
