# Vault PKI Control Plane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 기존 `acer-mgmt` 단일 Vault에 offline Root가 서명한 Intermediate CA와 팀별 최소 권한 발급 경계를 만들고, Raft snapshot·만료 알림·복구 runbook까지 운영 가능한 상태로 만든다.

**Architecture:** Root CA 개인키는 암호화된 채 Vaultwarden에 보관하고 Vault에는 RSA 3072 Intermediate 개인키만 둔다. `pki_int/` 하나 아래 팀별 PKI role과 기존 `kubernetes-ggg/`, `kubernetes-nmg/`, `kubernetes-khb/`, `kubernetes-ljw/`, `kubernetes-oje/` auth mount의 전용 cert-manager role을 만들며, 일일 관리 백업에 Vault Raft snapshot을 포함해 기존 MinIO→AWS S3 offsite 경로를 재사용한다.

**Tech Stack:** HashiCorp Vault 2.0.3 Community, Vault PKI secrets engine, Kubernetes auth, OpenSSL, Bash, Docker Compose, systemd, Prometheus textfile collector.

## Global Constraints

- Root CA는 RSA 4096, SHA-384, 10년, `CA:TRUE,pathlen:1`이다.
- Vault Intermediate CA는 RSA 3072, SHA-384, 3년, `CA:TRUE,pathlen:0`이며 개인키를 export하지 않는다.
- Leaf 기본 수명은 `2160h`(90일), 최대 수명도 `2160h`이고 cert-manager가 `720h`(30일) 전에 갱신한다.
- 팀과 auth mount의 고정 매핑은 `ggg`→`kubernetes-ggg/`, `nmg`→`kubernetes-nmg/`, `khb`→`kubernetes-khb/`, `ljw`→`kubernetes-ljw/`, `oje`→`kubernetes-oje/`이다.
- cert-manager ServiceAccount는 `cert-manager/vault-issuer`, ClusterIssuer는 `vault-internal`, Vault audience는 `vault://vault-internal`이다.
- 기존 ESO `scalecart` role/policy와 KV 경로는 수정하거나 재사용하지 않는다.
- 팀 클러스터 노드는 Vault Raft voter나 백업 저장소로 사용하지 않는다.
- Root CA 개인키·암호, Intermediate 개인키, Vault token, Kubernetes JWT는 Git에 넣지 않는다.
- `*.imcherry5778.xyz` 공개 HTTPS와 Chaos Dashboard JWT 자동화는 변경하지 않는다.
- Git 변경의 commit/push/MR/merge/정리 단계는 저장소 `AGENTS.md`의 순차 `y/n` 승인 규칙을 따른다. 아래 commit 단계는 승인 후 실행할 체크포인트이지 사전 승인이 아니다.

---

## File Structure

- Create `compose/config/vault-pki/root-ca-openssl.cnf`: Root/Intermediate X.509 extension의 단일 정의.
- Create `compose/config/vault-pki/teams.tsv`: 팀, auth mount, auth role, policy, PKI role의 고정 매핑.
- Create `compose/scripts/create-offline-root-ca.sh`: 저장소 밖 출력 디렉터리에 암호화 Root key/cert 생성.
- Create `compose/scripts/sign-vault-intermediate.sh`: Vault CSR을 offline Root로 서명하고 chain 생성.
- Create `compose/scripts/vault-pki-generate-intermediate-csr.sh`: `pki_int/` mount와 non-exportable Intermediate CSR 준비.
- Create `compose/scripts/vault-pki-install-intermediate.sh`: 서명 체인을 검증하고 Vault에 설치.
- Create `compose/scripts/bootstrap-vault-cert-manager.sh`: 팀별 PKI role, ACL policy, Kubernetes auth role 적용.
- Modify `compose/scripts/mgmt-db-backup.sh`: Raft snapshot, checksum, inspect 결과, textfile metric, MinIO 업로드 추가.
- Create `compose/stacks/observability/prometheus/config/alerts/infra-pki.yml`: snapshot/Intermediate/leaf/issuer 상태 알림.
- Create `compose/tests/test-offline-root-ca.sh`: 실제 OpenSSL 산출물의 키 크기·기간·pathlen 검증.
- Create `compose/tests/test-vault-pki-intermediate.sh`: Intermediate bootstrap/install 스크립트 계약 검증.
- Create `compose/tests/test-vault-cert-manager-boundaries.sh`: 5개 팀 role과 교차 팀 거부 계약 검증.
- Modify `compose/tests/test-mgmt-db-backup-config.sh`: Vault snapshot이 일일/offsite 경로에 포함되는지 검증.
- Create `compose/tests/test-vault-pki-alerts.sh`: 180일/30일/14일/7일과 Ready 실패 알림 검증.
- Create `docs/runbooks/vault-pki-operations.md`: 생성, Vaultwarden 보관, 교체, snapshot, restore 절차.

## Task 1: Offline Root CA 생성과 Intermediate 서명 도구

**Files:**
- Create: `compose/tests/test-offline-root-ca.sh`
- Create: `compose/config/vault-pki/root-ca-openssl.cnf`
- Create: `compose/scripts/create-offline-root-ca.sh`
- Create: `compose/scripts/sign-vault-intermediate.sh`

**Interfaces:**
- Consumes: 운영자가 지정한 Git 밖 디렉터리와 선택적 `ROOT_CA_PASS_FILE`.
- Produces: `root-ca.key`, `root-ca.crt`, `root-ca.sha256`, `vault-intermediate.crt`, `vault-intermediate-chain.pem`.

- [ ] **Step 1: Write the failing OpenSSL contract test**

```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf '%s' 'nonprod-test-passphrase' >"$tmp/pass"
chmod 600 "$tmp/pass"

ROOT_CA_PASS_FILE="$tmp/pass" "$root/compose/scripts/create-offline-root-ca.sh" "$tmp/root"
openssl x509 -in "$tmp/root/root-ca.crt" -noout -text >"$tmp/root.txt"
grep -Fq 'Public-Key: (4096 bit)' "$tmp/root.txt"
grep -Fq 'CA:TRUE, pathlen:1' "$tmp/root.txt"
grep -Fq 'Certificate Sign' "$tmp/root.txt"
openssl pkey -in "$tmp/root/root-ca.key" -passin file:"$tmp/pass" -noout

openssl req -new -newkey rsa:3072 -nodes -subj '/CN=Acer Lab Intermediate CA 2026' \
  -keyout "$tmp/intermediate.key" -out "$tmp/intermediate.csr" >/dev/null 2>&1
ROOT_CA_PASS_FILE="$tmp/pass" "$root/compose/scripts/sign-vault-intermediate.sh" \
  "$tmp/root" "$tmp/intermediate.csr" "$tmp/signed"
openssl verify -CAfile "$tmp/root/root-ca.crt" "$tmp/signed/vault-intermediate.crt"
openssl x509 -in "$tmp/signed/vault-intermediate.crt" -noout -text >"$tmp/intermediate.txt"
grep -Fq 'Public-Key: (3072 bit)' "$tmp/intermediate.txt"
grep -Fq 'CA:TRUE, pathlen:0' "$tmp/intermediate.txt"
echo 'OFFLINE_ROOT_CA_VALIDATION=PASS'
```

- [ ] **Step 2: Run the test and verify it fails because the tools do not exist**

Run:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' compose/tests/test-offline-root-ca.sh
```

Expected: non-zero with `compose/scripts/create-offline-root-ca.sh: No such file or directory`.

- [ ] **Step 3: Add the exact OpenSSL profile**

```ini
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = v3_root_ca

[ dn ]
CN = Acer Lab Root CA 2026
O = Acer Lab

[ v3_root_ca ]
basicConstraints = critical,CA:true,pathlen:1
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always

[ v3_intermediate_ca ]
basicConstraints = critical,CA:true,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
```

- [ ] **Step 4: Implement Root creation and Intermediate signing**

`create-offline-root-ca.sh` must use `umask 077`, refuse an existing output, call `openssl genpkey -algorithm RSA -aes-256-cbc -pkeyopt rsa_keygen_bits:4096`, and issue a 3650-day SHA-384 self-signed certificate with `v3_root_ca`. `sign-vault-intermediate.sh` must verify the CSR is RSA 3072, sign for 1095 days with `v3_intermediate_ca`, concatenate leaf-first chain order, and remove the generated `.srl` file.

```bash
passin=()
passout=()
if [[ -n "${ROOT_CA_PASS_FILE:-}" ]]; then
  [[ -f "$ROOT_CA_PASS_FILE" ]] || { echo 'ROOT_CA_PASS_FILE is missing' >&2; exit 1; }
  passin=(-passin "file:$ROOT_CA_PASS_FILE")
  passout=(-pass "file:$ROOT_CA_PASS_FILE")
fi

openssl genpkey -algorithm RSA -aes-256-cbc \
  -pkeyopt rsa_keygen_bits:4096 "${passout[@]}" -out "$out/root-ca.key"
openssl req -new -x509 -sha384 -days 3650 \
  -key "$out/root-ca.key" "${passin[@]}" \
  -config "$config" -extensions v3_root_ca -out "$out/root-ca.crt"
openssl x509 -in "$out/root-ca.crt" -outform DER | sha256sum | awk '{print $1}' >"$out/root-ca.sha256"
```

```bash
openssl req -in "$csr" -noout -verify
[[ "$(openssl req -in "$csr" -noout -text | sed -n 's/.*Public-Key: (\([0-9]*\) bit).*/\1/p' | head -1)" == 3072 ]]
openssl x509 -req -sha384 -days 1095 -in "$csr" \
  -CA "$root_dir/root-ca.crt" -CAkey "$root_dir/root-ca.key" "${passin[@]}" \
  -CAcreateserial -extfile "$config" -extensions v3_intermediate_ca \
  -out "$out/vault-intermediate.crt"
cat "$out/vault-intermediate.crt" "$root_dir/root-ca.crt" >"$out/vault-intermediate-chain.pem"
rm -f "$root_dir/root-ca.srl"
```

- [ ] **Step 5: Run the real cryptographic test**

Run:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' compose/tests/test-offline-root-ca.sh
```

Expected: `OFFLINE_ROOT_CA_VALIDATION=PASS`.

- [ ] **Step 6: Commit after explicit approval**

```bash
git add compose/config/vault-pki/root-ca-openssl.cnf compose/scripts/create-offline-root-ca.sh compose/scripts/sign-vault-intermediate.sh compose/tests/test-offline-root-ca.sh
git commit -m "feat(pki): offline Root CA 생성 도구 추가"
```

## Task 2: Vault Intermediate CSR과 체인 설치

**Files:**
- Create: `compose/tests/test-vault-pki-intermediate.sh`
- Create: `compose/scripts/vault-pki-generate-intermediate-csr.sh`
- Create: `compose/scripts/vault-pki-install-intermediate.sh`

**Interfaces:**
- Consumes: running `vault` container, `/tmp/.vt`, signed leaf-first PEM chain.
- Produces: non-exportable `pki_int/` key and CSR; installed 3-year Intermediate chain.

- [ ] **Step 1: Write the failing script contract**

```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
generate="$root/compose/scripts/vault-pki-generate-intermediate-csr.sh"
install="$root/compose/scripts/vault-pki-install-intermediate.sh"
for file in "$generate" "$install"; do [[ -x "$file" ]] || { echo "missing executable: $file" >&2; exit 1; }; done
grep -Fq 'vault secrets enable -path=pki_int pki' "$generate"
grep -Fq 'vault secrets tune -max-lease-ttl=26280h pki_int' "$generate"
grep -Fq 'pki_int/intermediate/generate/internal' "$generate"
grep -Fq 'key_type=rsa' "$generate"
grep -Fq 'key_bits=3072' "$generate"
grep -Fq 'pki_int/intermediate/set-signed' "$install"
grep -Fq 'CA:TRUE, pathlen:0' "$install"
grep -Fq 'openssl verify' "$install"
! grep -Eq 'generate/exported|root-ca.key|set -x' "$generate" "$install"
echo 'VAULT_PKI_INTERMEDIATE_CONTRACT=PASS'
```

- [ ] **Step 2: Verify red**

Run `& 'C:\Program Files\Git\bin\bash.exe' compose/tests/test-vault-pki-intermediate.sh` from PowerShell.

Expected: failure reporting the missing executable.

- [ ] **Step 3: Implement idempotent CSR generation**

The script takes one output path, creates `pki_int/` only when absent, refuses to replace an already configured CA, and never prints tokens.

```bash
mounts="$(vault_exec vault secrets list -format=json)"
if ! jq -e 'has("pki_int/")' <<<"$mounts" >/dev/null; then
  vault_exec vault secrets enable -path=pki_int pki >/dev/null
fi
vault_exec vault secrets tune -max-lease-ttl=26280h pki_int >/dev/null
if vault_exec vault read -field=certificate pki_int/cert/ca 2>/dev/null | grep -q 'BEGIN CERTIFICATE'; then
  echo 'pki_int already has a signed CA; use the rotation runbook' >&2
  exit 1
fi
vault_exec vault write -format=json pki_int/intermediate/generate/internal \
  common_name='Acer Lab Intermediate CA 2026' key_type=rsa key_bits=3072 \
  exclude_cn_from_sans=true | jq -er '.data.csr' >"$output"
chmod 600 "$output"
```

- [ ] **Step 4: Implement chain verification and installation**

The install script splits the first certificate as Intermediate, verifies `pathlen:0`, verifies it against the last Root certificate, checks 900–1100 remaining days, then streams the chain into the container and removes the temporary file.

```bash
openssl crl2pkcs7 -nocrl -certfile "$chain" | openssl pkcs7 -print_certs -out "$tmp/all.pem"
awk 'BEGIN{n=0}/BEGIN CERTIFICATE/{n++} n==1{print}' "$tmp/all.pem" >"$tmp/intermediate.crt"
awk 'BEGIN{n=0}/BEGIN CERTIFICATE/{n++} n==2{print}' "$tmp/all.pem" >"$tmp/root.crt"
openssl verify -CAfile "$tmp/root.crt" "$tmp/intermediate.crt"
openssl x509 -in "$tmp/intermediate.crt" -noout -text | grep -Fq 'CA:TRUE, pathlen:0'
docker exec -i "$VAULT_CONTAINER" sh -ceu '
  trap "rm -f /tmp/vault-intermediate-chain.pem" EXIT
  cat >/tmp/vault-intermediate-chain.pem
  export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt VAULT_TOKEN="$(cat /tmp/.vt)"
  vault write pki_int/intermediate/set-signed certificate=@/tmp/vault-intermediate-chain.pem >/dev/null
' <"$chain"
```

- [ ] **Step 5: Run static contract and shell syntax**

Run:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' -n compose/scripts/vault-pki-generate-intermediate-csr.sh compose/scripts/vault-pki-install-intermediate.sh
& 'C:\Program Files\Git\bin\bash.exe' compose/tests/test-vault-pki-intermediate.sh
```

Expected: `VAULT_PKI_INTERMEDIATE_CONTRACT=PASS`.

- [ ] **Step 6: Commit after explicit approval**

```bash
git add compose/scripts/vault-pki-generate-intermediate-csr.sh compose/scripts/vault-pki-install-intermediate.sh compose/tests/test-vault-pki-intermediate.sh
git commit -m "feat(vault): Intermediate CA 수명주기 도구 추가"
```

## Task 3: 팀별 PKI role과 cert-manager 인증 경계

**Files:**
- Create: `compose/config/vault-pki/teams.tsv`
- Create: `compose/tests/test-vault-cert-manager-boundaries.sh`
- Create: `compose/scripts/bootstrap-vault-cert-manager.sh`

**Interfaces:**
- Consumes: configured `pki_int/` and the five pre-existing Kubernetes auth mounts listed in Global Constraints.
- Produces: `ggg-internal`, `nmg-internal`, `khb-internal`, `ljw-internal`, `oje-internal` PKI roles plus the matching `cert-manager-ggg`, `cert-manager-nmg`, `cert-manager-khb`, `cert-manager-ljw`, `cert-manager-oje` policies and Kubernetes auth roles.

- [ ] **Step 1: Add the exact mapping and failing boundary test**

`teams.tsv` content:

```text
ggg	kubernetes-ggg	cert-manager-ggg	cert-manager-ggg	ggg-internal
nmg	kubernetes-nmg	cert-manager-nmg	cert-manager-nmg	nmg-internal
khb	kubernetes-khb	cert-manager-khb	cert-manager-khb	khb-internal
ljw	kubernetes-ljw	cert-manager-ljw	cert-manager-ljw	ljw-internal
oje	kubernetes-oje	cert-manager-oje	cert-manager-oje	oje-internal
```

The test loops over these rows and requires the bootstrap script to contain the exact policy path `pki_int/sign/$pki_role`, audience, ServiceAccount, namespace, 90-day TTL, `allow_any_name=false`, `allow_subdomains=false`, and `allow_ip_sans=false`. It must reject `*`, `scalecart`, `kv/data`, `root/generate`, and `sign-verbatim`.

```bash
while IFS=$'\t' read -r team mount auth_role policy pki_role; do
  grep -Fq "auth/${mount}/role/${auth_role}" "$script"
  grep -Fq 'bound_service_account_names=vault-issuer' "$script"
  grep -Fq 'bound_service_account_namespaces=cert-manager' "$script"
  grep -Fq 'audience=vault://vault-internal' "$script"
  grep -Fq "pki_int/sign/${pki_role}" "$script"
done <"$profiles"
! grep -Eq 'kv/data|scalecart|allow_any_name=true|allow_subdomains=true|allow_ip_sans=true|sign-verbatim|root/generate' "$script"
```

- [ ] **Step 2: Verify red**

Run `& 'C:\Program Files\Git\bin\bash.exe' compose/tests/test-vault-cert-manager-boundaries.sh` from PowerShell.

Expected: failure because `bootstrap-vault-cert-manager.sh` is missing.

- [ ] **Step 3: Implement the five exact roles**

The allowed DNS list is deliberately exact and common across clusters because the same in-cluster Chaos Mesh service names exist independently in each cluster:

```bash
allowed_domains='chaos-mesh-controller-manager,chaos-mesh-controller-manager.chaos-mesh,chaos-mesh-controller-manager.chaos-mesh.svc,chaos-daemon.chaos-mesh.org,controller-manager.chaos-mesh.org,localhost'

vault_cmd vault write "pki_int/roles/$pki_role" \
  allowed_domains="$allowed_domains" allow_bare_domains=true allow_subdomains=false \
  allow_glob_domains=false allow_wildcard_certificates=false allow_any_name=false \
  enforce_hostnames=true allow_localhost=true allow_ip_sans=false require_cn=false \
  use_csr_common_name=false use_csr_sans=true key_type=rsa key_bits=2048 \
  server_flag=true client_flag=true code_signing_flag=false email_protection_flag=false \
  ttl=2160h max_ttl=2160h >/dev/null

cat <<POLICY | vault_policy_write "$policy"
path "pki_int/sign/$pki_role" {
  capabilities = ["update"]
}
POLICY

vault_cmd vault write "auth/$mount/role/$auth_role" \
  bound_service_account_names=vault-issuer \
  bound_service_account_namespaces=cert-manager \
  audience=vault://vault-internal \
  token_policies="$policy" token_ttl=1m token_max_ttl=5m \
  token_no_default_policy=true token_type=batch >/dev/null
```

Before writing roles, the script must assert all five auth mounts exist and `pki_int/cert/ca` is readable. It must not enable or reconfigure Kubernetes auth mounts because ESO already depends on their reviewer configuration.

- [ ] **Step 4: Run contract and syntax tests**

```powershell
& 'C:\Program Files\Git\bin\bash.exe' -n compose/scripts/bootstrap-vault-cert-manager.sh
& 'C:\Program Files\Git\bin\bash.exe' compose/tests/test-vault-cert-manager-boundaries.sh
```

Expected: `VAULT_CERT_MANAGER_BOUNDARIES=PASS`.

- [ ] **Step 5: Commit after explicit approval**

```bash
git add compose/config/vault-pki/teams.tsv compose/scripts/bootstrap-vault-cert-manager.sh compose/tests/test-vault-cert-manager-boundaries.sh
git commit -m "feat(vault): 팀별 cert-manager 서명 경계 추가"
```

## Task 4: 일일 Raft snapshot과 offsite 경로

**Files:**
- Modify: `compose/tests/test-mgmt-db-backup-config.sh`
- Create: `compose/tests/test-minio-offsite-vault-encryption.sh`
- Modify: `compose/scripts/mgmt-db-backup.sh`
- Modify: `compose/scripts/minio-offsite-s3-backup.sh`

**Interfaces:**
- Consumes: healthy/unsealed `vault` container and existing MinIO backup credentials.
- Produces: `${BACKUP_ROOT}/vault-raft/${stamp}/vault.snap`, checksum, inspect report, node-exporter textfile metric, and an AWS S3 default-encrypted `db-backup/vault-raft/daily/${stamp}/` object.

- [ ] **Step 1: Extend the failing backup contract**

Add assertions requiring `create_vault_raft_snapshot`, `vault operator raft snapshot save`, `vault operator raft snapshot inspect`, `vault_raft_snapshot_last_success_timestamp_seconds`, `vault_pki_intermediate_expiration_timestamp_seconds`, and MinIO copy to `vault-raft/daily/${stamp}`. The new offsite test requires `mc encrypt info "aws/${AWS_S3_BUCKET}"` before any mirror and a hard failure unless the output reports `SSE-S3` or `SSE-KMS`. Assert the snapshot is not included in `mgmt-config.tar.gz` and no Vault token is printed.

- [ ] **Step 2: Run and verify red**

Run `& 'C:\Program Files\Git\bin\bash.exe' compose/tests/test-mgmt-db-backup-config.sh` from PowerShell.

Expected: failure on the missing `create_vault_raft_snapshot` string.

- [ ] **Step 3: Add the snapshot function and upload**

```bash
create_vault_raft_snapshot() {
  local destination="$1" container_snapshot=/tmp/acer-vault-raft.snap
  mkdir -p "$destination"
  chmod 700 "$destination"
  docker exec "$VAULT_CONTAINER" rm -f /tmp/acer-vault-raft.snap /tmp/acer-vault-raft.inspect
  docker exec "$VAULT_CONTAINER" sh -ceu '
    export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt VAULT_TOKEN="$(cat /tmp/.vt)"
    vault status >/dev/null
    vault operator raft snapshot save /tmp/acer-vault-raft.snap
    vault operator raft snapshot inspect /tmp/acer-vault-raft.snap >/tmp/acer-vault-raft.inspect
  '
  docker cp "$VAULT_CONTAINER:$container_snapshot" "$destination/vault.snap"
  docker exec "$VAULT_CONTAINER" cat /tmp/acer-vault-raft.inspect >"$destination/inspect.txt"
  docker exec "$VAULT_CONTAINER" rm -f "$container_snapshot" /tmp/acer-vault-raft.inspect
  sha256sum "$destination/vault.snap" >"$destination/SHA256SUMS"
  chmod 600 "$destination"/*
  local metric_tmp="${NODE_EXPORTER_TEXTFILE}/vault-raft.prom.$$"
  local ca_tmp="$destination/intermediate-ca.pem" not_after intermediate_expiry
  docker exec "$VAULT_CONTAINER" sh -ceu '
    export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt VAULT_TOKEN="$(cat /tmp/.vt)"
    vault read -field=certificate pki_int/cert/ca
  ' >"$ca_tmp"
  not_after="$(openssl x509 -in "$ca_tmp" -noout -enddate | cut -d= -f2-)"
  intermediate_expiry="$(date -u -d "$not_after" +%s)"
  rm -f "$ca_tmp"
  {
    printf 'vault_raft_snapshot_last_success_timestamp_seconds %s\n' "$(date +%s)"
    printf 'vault_pki_intermediate_expiration_timestamp_seconds %s\n' "$intermediate_expiry"
  } >"$metric_tmp"
  chmod 644 "$metric_tmp"
  mv "$metric_tmp" "${NODE_EXPORTER_TEXTFILE}/vault-raft.prom"
}
```

Set `VAULT_CONTAINER=${VAULT_CONTAINER:-vault}` and `NODE_EXPORTER_TEXTFILE=${NODE_EXPORTER_TEXTFILE:-${DATA_ROOT}/node-exporter-textfile}`. Add `vault_dir="${BACKUP_ROOT}/vault-raft/${stamp}"`, call the function, include it in the file-mode loop, and upload it with:

```bash
mc cp --recursive /backups/vault-raft/${stamp}/ local/${MINIO_BUCKET}/vault-raft/daily/${stamp}/
```

The existing `minio-offsite-s3-backup.sh` mirrors the whole `db-backup` bucket, so no second offsite job is added.

Before its first `mc mirror`, make the offsite job fail closed when AWS default encryption is absent:

```sh
encryption_info="$(mc encrypt info "aws/${AWS_S3_BUCKET}")"
printf '%s\n' "$encryption_info" | grep -Eqi 'SSE-S3|SSE-KMS' || {
  echo "AWS S3 bucket ${AWS_S3_BUCKET} has no verified default encryption" >&2
  exit 1
}
```

Do not enable encryption implicitly from the backup job. If the preflight fails, an operator must configure AWS bucket default encryption in a separately approved change and rerun the job.

- [ ] **Step 4: Run backup contract and existing secret-path regression**

```powershell
& 'C:\Program Files\Git\bin\bash.exe' compose/tests/test-mgmt-db-backup-config.sh
& 'C:\Program Files\Git\bin\bash.exe' compose/tests/test-backup-vault-secret-config.sh
& 'C:\Program Files\Git\bin\bash.exe' compose/tests/test-minio-offsite-vault-encryption.sh
```

Expected: all three exit 0.

- [ ] **Step 5: Commit after explicit approval**

```bash
git add compose/scripts/mgmt-db-backup.sh compose/scripts/minio-offsite-s3-backup.sh compose/tests/test-mgmt-db-backup-config.sh compose/tests/test-minio-offsite-vault-encryption.sh
git commit -m "feat(backup): Vault Raft snapshot을 offsite 경로에 포함"
```

## Task 5: PKI 알림과 운영 runbook

**Files:**
- Create: `compose/tests/test-vault-pki-alerts.sh`
- Create: `compose/stacks/observability/prometheus/config/alerts/infra-pki.yml`
- Create: `docs/runbooks/vault-pki-operations.md`
- Modify: `compose/scripts/mgmt-db-backup.sh`

**Interfaces:**
- Consumes: central Prometheus remote-write metrics and the two timestamp series in `vault-raft.prom`.
- Produces: actionable alerts and human-only Root/Intermediate rotation/restore gates.

- [ ] **Step 1: Write the failing alert contract**

Require these exact alerts and ranges:

```text
VaultRaftSnapshotStale > 93600 seconds
VaultIntermediateExpiresWithin180Days < 15552000 seconds
CertificateExpiresWithin30Days 14d <= remaining < 30d
CertificateExpiresWithin14Days 7d <= remaining < 14d
CertificateExpiresWithin7Days remaining < 7d
CertificateNotReady certmanager_certificate_ready_status{condition="True"} == 0
ClusterIssuerNotReady certmanager_clusterissuer_ready_status{name="vault-internal",condition="True"} == 0
CertManagerVaultSyncErrors increase(certmanager_controller_sync_error_count{controller=~"certificates-.*|certificaterequests-issuer-vault"}[15m]) > 0
```

Also require the existing Vault `/v1/sys/health?standbyok=true&perfstandbyok=true` target and forbid alert expressions that expose certificate subjects or Secret data as labels.

- [ ] **Step 2: Verify red**

Run `& 'C:\Program Files\Git\bin\bash.exe' compose/tests/test-vault-pki-alerts.sh` from PowerShell.

Expected: missing `infra-pki.yml`.

- [ ] **Step 3: Add the Prometheus rules**

```yaml
groups:
  - name: vault-pki
    interval: 1m
    rules:
      - alert: VaultRaftSnapshotStale
        expr: absent(vault_raft_snapshot_last_success_timestamp_seconds{job="mgmt-node"}) or (time() - vault_raft_snapshot_last_success_timestamp_seconds{job="mgmt-node"} > 93600)
        for: 30m
        labels: {severity: critical, team: platform, channel: infra, service: vault, scope: backup, cluster: mgmt}
        annotations:
          title: "[vault] Raft snapshot이 26시간 이상 갱신되지 않음"
          summary: "acer-mgmt-db-backup.service, Vault seal 상태, MinIO db-backup/vault-raft 경로를 확인하세요."
      - alert: CertificateExpiresWithin7Days
        expr: (certmanager_certificate_expiration_timestamp_seconds - time()) < 604800
        for: 15m
        labels: {severity: critical, team: platform, channel: infra, service: cert-manager, scope: pki}
        annotations:
          title: "[pki] 내부 인증서 만료 7일 미만"
          summary: "{{ $labels.cluster }}/{{ $labels.namespace }}/{{ $labels.name }} 갱신 실패 원인을 확인하세요."
```

Add the 30-day and 14-day mutually exclusive expressions using `>= 1209600` and `>= 604800`, plus `CertificateNotReady`, `ClusterIssuerNotReady`, and `CertManagerVaultSyncErrors`. Task 4's snapshot function exports `vault_pki_intermediate_expiration_timestamp_seconds` from `pki_int/cert/ca`; add `VaultIntermediateExpiresWithin180Days` with `(vault_pki_intermediate_expiration_timestamp_seconds - time()) < 15552000`, `for: 1h`, and `severity: warning`.

- [ ] **Step 4: Write the complete operator runbook**

The runbook must contain exact commands for:

1. Running Task 1 tools outside Git.
2. Verifying SHA-256 fingerprint and Root/Intermediate constraints.
3. Importing `root-ca.key`, `root-ca.crt`, passphrase, and fingerprint into distinct Vaultwarden fields/items.
4. Deleting workstation plaintext only after a second-machine recovery test.
5. Generating CSR, signing, installing chain, bootstrapping teams.
6. Daily snapshot manual verification and monthly isolated restore drill with Vault 2.0.3.
7. Intermediate rotation beginning 180 days before expiry with overlapping issuers.
8. Root rotation beginning two years before expiry.
9. Explicit statement that normal leaf issuance/renewal is automatic and Dashboard JWT is unrelated.

- [ ] **Step 5: Run alert and regression tests**

```powershell
& 'C:\Program Files\Git\bin\bash.exe' compose/tests/test-vault-pki-alerts.sh
& 'C:\Program Files\Git\bin\bash.exe' compose/tests/test-conservative-alert-expansion.sh
git diff --check
```

Expected: both tests pass and `git diff --check` prints nothing.

- [ ] **Step 6: Commit after explicit approval**

```bash
git add compose/stacks/observability/prometheus/config/alerts/infra-pki.yml compose/tests/test-vault-pki-alerts.sh docs/runbooks/vault-pki-operations.md compose/scripts/mgmt-db-backup.sh
git commit -m "docs(pki): 중앙 PKI 운영과 만료 대응 절차 추가"
```

## Task 6: acer-mgmt live bootstrap and evidence capture

**Files:**
- Modify only if actual commands differ: `docs/runbooks/vault-pki-operations.md`

**Interfaces:**
- Consumes: reviewed/merged control-plane code, operator-entered Root passphrase, Vaultwarden recovery proof.
- Produces: live `pki_int/`, five isolated sign roles, fresh offsite snapshot, evidence for the `acer-argocd` plan.

- [ ] **Step 1: Verify preconditions without mutation**

```bash
ssh -i C:\Users\User\Downloads\acer.pem user1@acer-mgmt \
  "docker exec vault sh -ceu 'export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt VAULT_TOKEN=\"\$(cat /tmp/.vt)\"; vault status; vault secrets list; vault auth list'"
```

Expected: initialized, unsealed, active; no existing `pki_int/`; `kubernetes-ggg/`, `kubernetes-nmg/`, `kubernetes-khb/`, `kubernetes-ljw/`, and `kubernetes-oje/` are present.

- [ ] **Step 2: Create and recover Root CA before using it**

Run the offline tool with a Git-excluded output directory. Store both files and passphrase in Vaultwarden, then export them on a second trusted machine and verify the fingerprint matches. Stop if recovery is not proven.

- [ ] **Step 3: Generate, sign, and install Intermediate**

```bash
ssh -i C:\Users\User\Downloads\acer.pem user1@acer-mgmt \
  "/home/user1/acer-mgmt/compose/scripts/vault-pki-generate-intermediate-csr.sh /home/user1/vault-intermediate.csr"
```

Copy only the CSR to the offline signing workstation, run `sign-vault-intermediate.sh`, copy only `vault-intermediate-chain.pem` back, then run `vault-pki-install-intermediate.sh`.

- [ ] **Step 4: Apply and deny-test team boundaries**

```bash
ssh -i C:\Users\User\Downloads\acer.pem user1@acer-mgmt \
  "/home/user1/acer-mgmt/compose/scripts/bootstrap-vault-cert-manager.sh"
```

For every team, read back the PKI role and auth role. Use a ggg-authenticated test token to sign an allowed `controller-manager.chaos-mesh.org` CSR through `ggg-internal`, then prove `pki_int/sign/nmg-internal` returns HTTP 403 and an arbitrary DNS SAN returns HTTP 400.

- [ ] **Step 5: Create and inspect the first snapshot**

```bash
ssh -i C:\Users\User\Downloads\acer.pem user1@acer-mgmt \
  "sudo systemctl start acer-mgmt-db-backup.service && sudo systemctl status --no-pager acer-mgmt-db-backup.service"
```

Expected: local checksum and inspect report exist, MinIO has a UTC timestamp-named child below `db-backup/vault-raft/daily/`, the AWS bucket reports `SSE-S3` or `SSE-KMS`, the offsite mirror completes, and both Prometheus textfile timestamps are current.

- [ ] **Step 6: Prove an isolated restore before cluster rollout**

Execute the runbook's disposable Docker volume restore drill with `hashicorp/vault:2.0.3`: start an isolated single-node Raft Vault on a non-production port, initialize and unseal only that disposable instance, run `vault operator raft snapshot restore -force`, verify `pki_int/` and all five Kubernetes auth mounts, then destroy the disposable container, network, and volume. Record the snapshot checksum and pass/fail evidence without recording unseal keys or tokens. Do not bind the restored instance to the production proxy network.

- [ ] **Step 7: Capture the exact public trust artifact**

Copy `root-ca.crt` only to the `acer-argocd` implementation worktree as `security/cert-manager/base/root-ca.crt`. Record the derived SHA-256 fingerprint in that repository's test contract; never copy `root-ca.key` or its passphrase.

## Final Verification

Run from `acer-mgmt`:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' compose/tests/test-offline-root-ca.sh
& 'C:\Program Files\Git\bin\bash.exe' compose/tests/test-vault-pki-intermediate.sh
& 'C:\Program Files\Git\bin\bash.exe' compose/tests/test-vault-cert-manager-boundaries.sh
& 'C:\Program Files\Git\bin\bash.exe' compose/tests/test-mgmt-db-backup-config.sh
& 'C:\Program Files\Git\bin\bash.exe' compose/tests/test-minio-offsite-vault-encryption.sh
& 'C:\Program Files\Git\bin\bash.exe' compose/tests/test-vault-pki-alerts.sh
& 'C:\Program Files\Git\bin\bash.exe' compose/tests/test-cluster-chaos-dashboard-tokens.sh
git diff --check
```

Expected: all sentinels report `PASS`; Dashboard token test remains unchanged; no secret material appears in `git status`, `git diff`, or `git grep`.

## References

- HashiCorp Vault PKI setup: https://developer.hashicorp.com/vault/docs/secrets/pki/setup
- HashiCorp Vault Intermediate CA setup: https://developer.hashicorp.com/vault/docs/secrets/pki/quick-start-intermediate-ca
- HashiCorp Vault Kubernetes auth role API: https://developer.hashicorp.com/vault/api-docs/auth/kubernetes
- cert-manager Vault issuer Kubernetes auth: https://cert-manager.io/docs/configuration/vault/
