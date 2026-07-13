# Vault PKI 운영 Runbook

이 문서는 단일 `acer-mgmt` Vault와 다섯 팀 클러스터의 내부 인증서 발급면을
운영하는 절차다. Vaultwarden은 이 비프로덕션 환경에서 수용한 트레이드오프이며 HSM이 아니다.
Root 개인키를 온라인 Vault나 Git에 넣지 않으며, 정상 leaf 발급과 갱신은 cert-manager가 자동 처리한다.
Chaos Dashboard JWT와 PKI 인증서는 서로 무관하다.

## 역할과 사람 개입 지점

- 자동: cert-manager의 leaf 발급/갱신, Vault 팀별 서명, 일일 Raft snapshot, MinIO와
  AWS S3 offsite 복제, Prometheus 경보 평가.
- 사람 전용: 최초 Root 생성과 복구 증명, Intermediate/Root 교체 승인과 offline
  서명, 월간 복구 훈련, 장애 시 rollback 결정.
- 어떤 명령도 실제 passphrase, Vault token, unseal key 또는 Kubernetes JWT를
  인자로 받지 않는다. 예시의 경로와 공개 fingerprint만 기록할 수 있다.

## 1. Offline Root 생성

Git working tree 밖의 암호화된 로컬 디스크에서만 실행한다. 터미널 history에
passphrase를 입력하지 않고, 권한 0600인 임시 파일을 통해 도구에 전달한다.

```bash
set -euo pipefail
umask 077
REPO="$HOME/acer-mgmt"
OFFLINE_BASE="$HOME/offline-ca"
mkdir -p -m 700 "$OFFLINE_BASE"
ROOT_WORK="$(mktemp -d "$OFFLINE_BASE/session-XXXXXXXX")"
PASS_FILE="$(mktemp "$OFFLINE_BASE/.root-pass-XXXXXXXX")"
chmod 600 "$PASS_FILE"
read -rsp '새 Root CA passphrase: ' ROOT_CA_PASSPHRASE; printf '\n'
printf '%s' "$ROOT_CA_PASSPHRASE" >"$PASS_FILE"
unset ROOT_CA_PASSPHRASE
ROOT_CA_PASS_FILE="$PASS_FILE" \
  "$REPO/compose/scripts/create-offline-root-ca.sh" "$ROOT_WORK/root"
"$REPO/compose/scripts/verify-vault-pki-artifacts.sh" --root-only \
  "$ROOT_WORK/root/root-ca.crt" "$ROOT_WORK/root/root-ca.sha256"
```

`ROOT_WORK`와 `PASS_FILE`은 반드시 Git 밖이어야 한다. `git -C "$REPO" status
--short`에 이 경로가 나타나면 즉시 중단한다.

### Root 공개 정보와 제약 검증

```bash
set -euo pipefail
openssl pkey -in "$ROOT_WORK/root/root-ca.key" \
  -passin "file:$PASS_FILE" -noout -check
openssl x509 -in "$ROOT_WORK/root/root-ca.crt" -noout -text >"$ROOT_WORK/root.txt"
grep -F 'Public-Key: (4096 bit)' "$ROOT_WORK/root.txt"
grep -F 'Signature Algorithm: sha384WithRSAEncryption' "$ROOT_WORK/root.txt"
grep -F 'CA:TRUE, pathlen:1' "$ROOT_WORK/root.txt"
grep -F 'Certificate Sign' "$ROOT_WORK/root.txt"
openssl verify -check_ss_sig -CAfile "$ROOT_WORK/root/root-ca.crt" \
  "$ROOT_WORK/root/root-ca.crt"
openssl x509 -in "$ROOT_WORK/root/root-ca.crt" -noout -dates -fingerprint -sha256
openssl x509 -in "$ROOT_WORK/root/root-ca.crt" -outform DER | sha256sum
cat "$ROOT_WORK/root/root-ca.sha256"
```

마지막 두 SHA-256 값이 byte-for-byte 같아야 한다. `notBefore`와 `notAfter`는 생성
시각 기준 3650일(10년), basicConstraints는 critical `CA:TRUE, pathlen:1`, keyUsage는
critical Certificate Sign/CRL Sign이어야 한다. 하나라도 다르면 보관하거나 서명하지
말고 새 빈 session 디렉터리에서 다시 생성한다.

## 2. Vaultwarden 보관과 두 번째 장비 복구 gate

Vaultwarden에는 접근 권한을 제한한 collection을 만들고 다음을 서로 구별되는
attachment/field 또는 별도 item으로 저장한다.

1. encrypted `root-ca.key` attachment
2. public `root-ca.crt` attachment
3. 숨김 필드 `Root CA passphrase`
4. 공개 필드 `SHA-256 fingerprint`

메모에는 생성일, 예정 교체일, 생성 담당자 두 명만 적는다. shell history, 채팅,
티켓, Git에는 실제 값을 복사하지 않는다.

두 번째 신뢰 장비에서 새 빈 암호화 디렉터리로 네 항목을 export한다. passphrase는
아래처럼 terminal prompt에서 읽어 임시 파일에 기록하고, key 복호화와 공개
fingerprint 및 self-signature를 다시 검증한다.

```bash
set -euo pipefail
umask 077
RECOVERY_DIR="$(mktemp -d "$HOME/offline-ca/recovery-XXXXXXXX")"
RECOVERY_PASS="$(mktemp "$HOME/offline-ca/.recovery-pass-XXXXXXXX")"
chmod 600 "$RECOVERY_PASS"
read -rsp 'Vaultwarden에서 복구한 Root CA passphrase: ' RECOVERED_PASSPHRASE; printf '\n'
printf '%s' "$RECOVERED_PASSPHRASE" >"$RECOVERY_PASS"
unset RECOVERED_PASSPHRASE
# Vaultwarden UI에서 두 attachment를 RECOVERY_DIR/root-ca.key 및 root-ca.crt로 export한다.
chmod 600 "$RECOVERY_DIR/root-ca.key" "$RECOVERY_DIR/root-ca.crt"
read -rp 'Vaultwarden의 Root SHA-256 fingerprint: ' RECOVERED_ROOT_SHA256
[[ "$RECOVERED_ROOT_SHA256" =~ ^[0-9a-fA-F]{64}$ ]]
printf '%s\n' "${RECOVERED_ROOT_SHA256,,}" >"$RECOVERY_DIR/root-ca.sha256"
unset RECOVERED_ROOT_SHA256
openssl pkey -in "$RECOVERY_DIR/root-ca.key" -passin "file:$RECOVERY_PASS" -noout -check
openssl verify -check_ss_sig -CAfile "$RECOVERY_DIR/root-ca.crt" "$RECOVERY_DIR/root-ca.crt"
openssl x509 -in "$RECOVERY_DIR/root-ca.crt" -outform DER | sha256sum
"$REPO/compose/scripts/verify-vault-pki-artifacts.sh" --root-only \
  "$RECOVERY_DIR/root-ca.crt" "$RECOVERY_DIR/root-ca.sha256"
```

출력 fingerprint가 Vaultwarden 공개 필드와 최초 `root-ca.sha256`에 모두 일치해야
한다. 복구 검증이 성공하기 전에는 원본 평문을 삭제하지 않는다. 두 번째 담당자가
일치 결과를 확인한 뒤에만 다음 cleanup gate를 실행한다.

```bash
set -euo pipefail
printf 'RECOVERY VERIFIED\n'
case "$PASS_FILE:$ROOT_WORK" in
  "$HOME"/offline-ca/.root-pass-*:"$HOME"/offline-ca/session-*) ;;
  *) echo 'unsafe cleanup path' >&2; exit 1 ;;
esac
rm -f -- "$PASS_FILE"
find "$ROOT_WORK" -xdev -depth -delete
unset PASS_FILE ROOT_WORK
```

SSD/CoW 파일시스템에서 `shred`는 완전 삭제를 보장하지 않는다. 이 절차는 암호화된
작업 볼륨을 사용하고, cleanup 뒤 그 볼륨의 암호화 key도 폐기하는 것을 전제로 한다.
두 번째 장비의 recovery export도 검증 증거만 남긴 뒤 같은 방식으로 정리한다.

## 3. Intermediate 최초 설치와 팀 경계 적용

### 온라인 Vault에서 non-exportable CSR 생성

사전 조건은 Vault가 active/unsealed이고 기존 `pki_int/`에 signed CA가 없으며,
`/tmp/.vt`가 컨테이너 안에서만 읽히는 것이다. 명령 출력에는 token이 나타나지 않는다.

```bash
set -euo pipefail
cd "$HOME/acer-mgmt"
umask 077
CSR_DIR="$(mktemp -d "$HOME/vault-pki-csr-XXXXXXXX")"
./compose/scripts/vault-pki-generate-intermediate-csr.sh \
  "$CSR_DIR/vault-intermediate.csr"
openssl req -in "$CSR_DIR/vault-intermediate.csr" -noout -verify -text |
  grep -E 'Public-Key: \(3072 bit\)|Public Key Algorithm: rsaEncryption'
```

CSR만 offline 장비로 옮긴다. Vault 내부 Intermediate 개인키는 export하거나
Vaultwarden에 넣지 않는다.

### Offline 서명과 검증

Vaultwarden 복구가 증명된 offline 장비에서 Root attachment를 임시 암호화 작업
볼륨에 복구하고, passphrase file을 terminal prompt로 만든 뒤 실행한다.

```bash
set -euo pipefail
umask 077
SIGNED_DIR="$OFFLINE_BASE/signed-$(date -u +%Y%m%dT%H%M%SZ)"
ROOT_CA_PASS_FILE="$RECOVERY_PASS" \
  "$REPO/compose/scripts/sign-vault-intermediate.sh" \
  "$RECOVERY_DIR" "$OFFLINE_BASE/vault-intermediate.csr" "$SIGNED_DIR"
openssl verify -CAfile "$RECOVERY_DIR/root-ca.crt" \
  "$SIGNED_DIR/vault-intermediate.crt"
openssl x509 -in "$SIGNED_DIR/vault-intermediate.crt" -noout -text \
  >"$SIGNED_DIR/intermediate.txt"
grep -F 'Public-Key: (3072 bit)' "$SIGNED_DIR/intermediate.txt"
grep -F 'Signature Algorithm: sha384WithRSAEncryption' "$SIGNED_DIR/intermediate.txt"
grep -F 'CA:TRUE, pathlen:0' "$SIGNED_DIR/intermediate.txt"
openssl x509 -in "$SIGNED_DIR/vault-intermediate.crt" -noout -dates -fingerprint -sha256
openssl verify -show_chain -CAfile "$RECOVERY_DIR/root-ca.crt" \
  "$SIGNED_DIR/vault-intermediate.crt"
"$REPO/compose/scripts/verify-vault-pki-artifacts.sh" \
  "$RECOVERY_DIR/root-ca.crt" "$RECOVERY_DIR/root-ca.sha256" \
  "$SIGNED_DIR/vault-intermediate.crt" \
  "$SIGNED_DIR/vault-intermediate-chain.pem"
```

Intermediate는 1095일(3년), RSA 3072, SHA-384, critical `CA:TRUE, pathlen:0`,
Certificate Sign/CRL Sign이어야 하며 chain은 Intermediate 먼저, Root 다음 순서다.

### 체인 설치와 고정 5팀 bootstrap

서버로는 공개 `vault-intermediate-chain.pem`만 복사한다. Root key/passphrase와
Intermediate key는 복사하지 않는다.

```bash
set -euo pipefail
cd "$HOME/acer-mgmt"
umask 077
CHAIN_DIR="$(mktemp -d "$HOME/vault-pki-chain-XXXXXXXX")"
# 검증된 공개 chain을 CHAIN_DIR/vault-intermediate-chain.pem으로 전송한다.
chmod 600 "$CHAIN_DIR/vault-intermediate-chain.pem"
./compose/scripts/vault-pki-install-intermediate.sh \
  "$CHAIN_DIR/vault-intermediate-chain.pem"
./compose/scripts/bootstrap-vault-cert-manager.sh
docker exec vault sh -ceu '
  export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt
  VAULT_TOKEN="$(cat /tmp/.vt)"; export VAULT_TOKEN
  vault read pki_int/cert/ca >/dev/null
  vault list pki_int/roles
  for team in ggg nmg khb ljw oje; do
    vault read "auth/kubernetes-${team}/role/cert-manager-${team}" >/dev/null
  done
'
rm -f -- "$CHAIN_DIR/vault-intermediate-chain.pem"
rmdir -- "$CHAIN_DIR"
```

정상 상태에서는 이후 사람이 leaf CSR을 수동 서명하지 않는다. cert-manager가
`cert-manager/vault-issuer` ServiceAccount와 팀별 auth role을 이용하고, 90일 leaf를
만료 30일 전에 자동 갱신한다.

## 4. 일일 snapshot 확인

자동 작업은 `acer-mgmt-db-backup.timer`가 수행한다. 수동 점검은 같은 service를
실행하고 가장 최근 timestamp 디렉터리의 checksum, inspect, MinIO object, textfile
metric을 확인한다.
아래 image entrypoint 명령은 컨테이너 내부의 `vault operator raft snapshot inspect`와
동일하지만 production Vault에 접속하지 않고 snapshot 파일만 읽는다.

```bash
set -euo pipefail
sudo systemctl start acer-mgmt-db-backup.service
sudo systemctl status --no-pager acer-mgmt-db-backup.service
LATEST="$(find /home/mgmt-data/backups/vault-raft -mindepth 1 -maxdepth 1 -type d \
  -printf '%f\n' | sort | tail -1)"
test -n "$LATEST"
(cd "/home/mgmt-data/backups/vault-raft/$LATEST" && sha256sum -c SHA256SUMS)
docker run --rm -i --entrypoint vault hashicorp/vault:2.0.3 \
  operator raft snapshot inspect /dev/stdin \
  <"/home/mgmt-data/backups/vault-raft/$LATEST/vault.snap"
grep -E '^vault_(raft_snapshot_last_success|pki_intermediate_expiration)_timestamp_seconds [0-9]+$' \
  /home/mgmt-data/node-exporter-textfile/vault-raft.prom
```

MinIO에서 `db-backup/vault-raft/daily/$LATEST/` 아래 `vault.snap`, `inspect.txt`,
`SHA256SUMS`를 확인한다. AWS offsite 실행 전 `mc encrypt info` 결과가 SSE-S3 또는
SSE-KMS여야 한다. encryption preflight가 실패하면 backup job에서 암호화를 임의로
켜지 말고, 별도 승인으로 bucket default encryption을 구성한 다음 재실행한다.

Prometheus rule 변경은 CI 또는 Docker가 가능한 검토 장비에서 multi-arch digest로
고정한 같은 `promtool`을 통과해야 한다.

```bash
set -euo pipefail
PROMTOOL_IMAGE='prom/prometheus@sha256:69f5241418838263316593f7274a304b095c40bcf22e57272865da91bd60a8ac'
docker run --rm \
  -v "$HOME/acer-mgmt/compose/stacks/observability/prometheus/config/alerts:/rules:ro" \
  --entrypoint promtool "$PROMTOOL_IMAGE" check rules /rules/infra-pki.yml
```

## 5. 월간 격리 복구 훈련 (Vault 2.0.3)

훈련은 backup job이 만든 원본 checksum으로 먼저 검증한 snapshot만 사용한다.
컨테이너는 host port를 publish하지 않고 실행마다 새 `--internal` network 하나에만
붙인다. 프로덕션 proxy/network에 연결하지 않는다. 실제 unseal key와 admin token은
`read -rsp`로 받고 표준입력으로만 컨테이너에 전달한다. snapshot은 16 MiB `/tmp`에
복사하지 않고 검증 전용 디렉터리를 read-only bind mount한다.

```bash
set -euo pipefail
umask 077
VAULT_IMAGE='hashicorp/vault@sha256:a296a888b118615dc01d5f1a6846e6d4a7277946caaed5b447008fff5fe06b54'
SOURCE_SNAPSHOT_DIR="$(find /home/mgmt-data/backups/vault-raft \
  -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)"
case "$SOURCE_SNAPSHOT_DIR" in /home/mgmt-data/backups/vault-raft/*) ;; *) exit 1 ;; esac
test -s "$SOURCE_SNAPSHOT_DIR/vault.snap"
test -s "$SOURCE_SNAPSHOT_DIR/SHA256SUMS"
(cd "$SOURCE_SNAPSHOT_DIR" && sha256sum -c SHA256SUMS)

DRILL_DIR="$(mktemp -d "$HOME/vault-restore-drill-XXXXXXXX")"
VERIFIED_DIR="$DRILL_DIR/verified"
install -d -m 700 "$VERIFIED_DIR"
cp -- "$SOURCE_SNAPSHOT_DIR/vault.snap" "$SOURCE_SNAPSHOT_DIR/SHA256SUMS" "$VERIFIED_DIR/"
(cd "$VERIFIED_DIR" && sha256sum -c SHA256SUMS)

RUN_ID="$(openssl rand -hex 12)"
[[ "$RUN_ID" =~ ^[0-9a-f]{24}$ ]]
DRILL_CONTAINER="vault-restore-${RUN_ID}"
DRILL_NETWORK="vault-restore-net-${RUN_ID}"
DRILL_VOLUME="vault-restore-data-${RUN_ID}"
NETWORK_CREATED=0
VOLUME_CREATED=0
CONTAINER_CREATED=0

cat >"$DRILL_DIR/restore.hcl" <<'HCL'
ui = false
disable_mlock = true
storage "raft" {
  path = "/vault/data"
  node_id = "isolated-restore-drill"
}
listener "tcp" {
  address = "127.0.0.1:8200"
  tls_disable = true
}
HCL
cleanup_restore_drill() {
  if [[ "$CONTAINER_CREATED" == 1 ]] &&
     [[ "$(docker container inspect -f '{{ index .Config.Labels "acer.restore.run" }}' "$DRILL_CONTAINER" 2>/dev/null || true)" == "$RUN_ID" ]]; then
    docker rm -f "$DRILL_CONTAINER" >/dev/null 2>&1 || true
  fi
  if [[ "$VOLUME_CREATED" == 1 ]] &&
     [[ "$(docker volume inspect -f '{{ index .Labels "acer.restore.run" }}' "$DRILL_VOLUME" 2>/dev/null || true)" == "$RUN_ID" ]]; then
    docker volume rm "$DRILL_VOLUME" >/dev/null 2>&1 || true
  fi
  if [[ "$NETWORK_CREATED" == 1 ]] &&
     [[ "$(docker network inspect -f '{{ index .Labels "acer.restore.run" }}' "$DRILL_NETWORK" 2>/dev/null || true)" == "$RUN_ID" ]]; then
    docker network rm "$DRILL_NETWORK" >/dev/null 2>&1 || true
  fi
  case "${DRILL_DIR:-}" in "$HOME"/vault-restore-drill-*) find "$DRILL_DIR" -xdev -depth -delete ;; esac
}
trap cleanup_restore_drill EXIT

for existing in \
  "$(docker container inspect "$DRILL_CONTAINER" >/dev/null 2>&1 && echo container || true)" \
  "$(docker network inspect "$DRILL_NETWORK" >/dev/null 2>&1 && echo network || true)" \
  "$(docker volume inspect "$DRILL_VOLUME" >/dev/null 2>&1 && echo volume || true)"; do
  [[ -z "$existing" ]] || { echo "refusing pre-existing $existing resource" >&2; exit 1; }
done

docker pull "$VAULT_IMAGE" >/dev/null
docker network create --internal --label "acer.restore.run=$RUN_ID" "$DRILL_NETWORK" >/dev/null
NETWORK_CREATED=1
[[ "$(docker network inspect -f '{{ index .Labels "acer.restore.run" }}' "$DRILL_NETWORK")" == "$RUN_ID" ]]
docker volume create --label "acer.restore.run=$RUN_ID" "$DRILL_VOLUME" >/dev/null
VOLUME_CREATED=1
[[ "$(docker volume inspect -f '{{ index .Labels "acer.restore.run" }}' "$DRILL_VOLUME")" == "$RUN_ID" ]]
docker create --name "$DRILL_CONTAINER" --network "$DRILL_NETWORK" \
  --label "acer.restore.run=$RUN_ID" \
  --read-only --cap-drop ALL --security-opt no-new-privileges:true \
  --tmpfs /tmp:size=16m,mode=1777 \
  -v "$DRILL_VOLUME:/vault/data" \
  -v "$VERIFIED_DIR:/vault/restore:ro" \
  -v "$DRILL_DIR/restore.hcl:/vault/config/restore.hcl:ro" \
  "$VAULT_IMAGE" server -config=/vault/config/restore.hcl >/dev/null
CONTAINER_CREATED=1
[[ "$(docker container inspect -f '{{ index .Config.Labels "acer.restore.run" }}' "$DRILL_CONTAINER")" == "$RUN_ID" ]]
docker start "$DRILL_CONTAINER" >/dev/null

until docker exec -e VAULT_ADDR=http://127.0.0.1:8200 "$DRILL_CONTAINER" sh -ceu '
  status=0
  vault status >/dev/null 2>&1 || status=$?
  [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
'; do sleep 1; done
docker exec -e VAULT_ADDR=http://127.0.0.1:8200 "$DRILL_CONTAINER" \
  vault operator init -key-shares=1 -key-threshold=1 -format=json >"$DRILL_DIR/init.json"
jq -er '.unseal_keys_b64[0]' "$DRILL_DIR/init.json" >"$DRILL_DIR/drill-unseal"
jq -er '.root_token' "$DRILL_DIR/init.json" >"$DRILL_DIR/drill-token"
docker exec -i -e VAULT_ADDR=http://127.0.0.1:8200 "$DRILL_CONTAINER" \
  vault operator unseal <"$DRILL_DIR/drill-unseal" >/dev/null
docker exec -i "$DRILL_CONTAINER" sh -ceu 'umask 077; cat >/tmp/drill-token' \
  <"$DRILL_DIR/drill-token"
docker exec "$DRILL_CONTAINER" sh -ceu '
  export VAULT_ADDR=http://127.0.0.1:8200
  VAULT_TOKEN="$(cat /tmp/drill-token)"; export VAULT_TOKEN
  vault operator raft snapshot restore -force /vault/restore/vault.snap
'
```

restore 뒤 storage barrier가 원본 snapshot 것으로 바뀐다. 현재 production unseal
threshold 횟수만큼 아래 loop를 실행한다. 입력값은 echo, log, file에 남지 않는다.

```bash
read -rp '현재 production unseal threshold: ' SOURCE_UNSEAL_THRESHOLD
[[ "$SOURCE_UNSEAL_THRESHOLD" =~ ^[1-9][0-9]*$ ]]
for ((i=1; i<=SOURCE_UNSEAL_THRESHOLD; i++)); do
  read -rsp "production unseal key ${i}: " SOURCE_UNSEAL_KEY; printf '\n'
  printf '%s\n' "$SOURCE_UNSEAL_KEY" | docker exec -i \
    -e VAULT_ADDR=http://127.0.0.1:8200 "$DRILL_CONTAINER" vault operator unseal >/dev/null
  unset SOURCE_UNSEAL_KEY
done
read -rsp 'production Vault 검증용 admin token: ' SOURCE_VAULT_TOKEN; printf '\n'
printf '%s' "$SOURCE_VAULT_TOKEN" | docker exec -i "$DRILL_CONTAINER" \
  sh -ceu 'umask 077; cat >/tmp/source-token'
unset SOURCE_VAULT_TOKEN
RESTORED_SECRETS="$(docker exec "$DRILL_CONTAINER" sh -ceu '
  export VAULT_ADDR=http://127.0.0.1:8200
  VAULT_TOKEN="$(cat /tmp/source-token)"; export VAULT_TOKEN
  vault status >/dev/null
  vault secrets list -format=json
')"
RESTORED_AUTH="$(docker exec "$DRILL_CONTAINER" sh -ceu '
  export VAULT_ADDR=http://127.0.0.1:8200
  VAULT_TOKEN="$(cat /tmp/source-token)"; export VAULT_TOKEN
  vault auth list -format=json
')"
jq -e '."pki_int/".type == "pki"' <<<"$RESTORED_SECRETS"
for team in ggg nmg khb ljw oje; do
  jq -e --arg mount "kubernetes-${team}/" '.[$mount].type == "kubernetes"' \
    <<<"$RESTORED_AUTH"
done
unset RESTORED_SECRETS RESTORED_AUTH
docker exec "$DRILL_CONTAINER" rm -f /tmp/source-token /tmp/drill-token
(cd "$VERIFIED_DIR" && sha256sum -c SHA256SUMS)
EVIDENCE_DIR="$HOME/vault-restore-evidence"
install -d -m 700 "$EVIDENCE_DIR"
{
  docker image inspect "$VAULT_IMAGE" --format 'image_id={{.Id}} repo_digests={{json .RepoDigests}}'
  docker run --rm --entrypoint vault "$VAULT_IMAGE" version
  sha256sum "$VERIFIED_DIR/vault.snap"
  printf 'restore_result=PASS run_id=%s\n' "$RUN_ID"
} >"$EVIDENCE_DIR/${RUN_ID}.txt"
chmod 600 "$EVIDENCE_DIR/${RUN_ID}.txt"
echo 'ISOLATED_VAULT_RESTORE=PASS'
cleanup_restore_drill
trap - EXIT
```

증거에는 snapshot SHA-256, `docker image inspect` image ID/RepoDigest, `vault version`,
PASS/FAIL만 남긴다.
`init.json`, unseal key, token 또는 snapshot 자체는 증거에 첨부하지 않는다. 실패해도
trap이 disposable container, network, volume, 임시 파일을 지운다.

## 6. Intermediate 교체: 만료 180일 전 시작

Intermediate 만료 180일 전 `VaultIntermediateExpiresWithin180Days` 경보를 기준으로
교체 계획을 승인한다. 새
`pki_int_next/`와 `vault-internal-next`를 병행해 기존 issuer를 건드리지 않는 방식이다.
이 기간을 dual trust/overlap 기간으로 운용한다.

다음 명령은 기존 mount를 변경하지 않고 새 mount와 새 auth role을 만든다. 시작 전에
`ROTATE_DIR`를 Git 밖 0700 디렉터리로 만들고 최신 snapshot을 확인한다.

```bash
set -euo pipefail
umask 077
cd "$HOME/acer-mgmt"
ROTATE_DIR="$(mktemp -d "$HOME/vault-pki-rotate-XXXXXXXX")"
docker exec vault sh -ceu '
  export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt
  VAULT_TOKEN="$(cat /tmp/.vt)"; export VAULT_TOKEN
  vault secrets enable -path=pki_int_next pki
  vault secrets tune -max-lease-ttl=26280h pki_int_next
  vault write -format=json pki_int_next/intermediate/generate/internal \
    common_name="Acer Lab Intermediate CA next" key_type=rsa key_bits=3072 \
    exclude_cn_from_sans=true
' | jq -er '.data.csr' >"$ROTATE_DIR/vault-intermediate-next.csr"
openssl req -in "$ROTATE_DIR/vault-intermediate-next.csr" -noout -verify -text |
  grep -F 'Public-Key: (3072 bit)'
```

CSR만 offline 장비로 전달하고 3절의 Root recovery gate를 다시 수행한다. offline
장비에서 다음과 같이 기존 서명 도구로 새 공개 chain을 만든다.

```bash
set -euo pipefail
umask 077
ROOT_CA_PASS_FILE="$RECOVERY_PASS" \
  "$REPO/compose/scripts/sign-vault-intermediate.sh" \
  "$RECOVERY_DIR" "$OFFLINE_BASE/vault-intermediate-next.csr" \
  "$OFFLINE_BASE/signed-next"
openssl verify -CAfile "$RECOVERY_DIR/root-ca.crt" \
  "$OFFLINE_BASE/signed-next/vault-intermediate.crt"
"$REPO/compose/scripts/verify-vault-pki-artifacts.sh" \
  "$RECOVERY_DIR/root-ca.crt" "$RECOVERY_DIR/root-ca.sha256" \
  "$OFFLINE_BASE/signed-next/vault-intermediate.crt" \
  "$OFFLINE_BASE/signed-next/vault-intermediate-chain.pem"
```

검증된 `vault-intermediate-chain.pem`만 mgmt의 `$ROTATE_DIR`로 돌려보낸 뒤 설치하고
old/new와 분리된 팀별 발급 경계를 만든다.

```bash
set -euo pipefail
umask 077
CHAIN="$ROTATE_DIR/vault-intermediate-chain.pem"
ROOT_FROM_CHAIN="$ROTATE_DIR/root-from-chain.pem"
INTERMEDIATE_FROM_CHAIN="$ROTATE_DIR/intermediate-from-chain.pem"
awk 'BEGIN{n=0} /BEGIN CERT/{n++} n==1{print}' "$CHAIN" >"$INTERMEDIATE_FROM_CHAIN"
awk 'BEGIN{n=0} /BEGIN CERT/{n++} n==2{print}' "$CHAIN" >"$ROOT_FROM_CHAIN"
openssl verify -CAfile "$ROOT_FROM_CHAIN" "$INTERMEDIATE_FROM_CHAIN"
docker exec -i vault sh -ceu '
  umask 077
  chain="$(mktemp /tmp/pki-next-chain.XXXXXXXX)"
  trap '\''rm -f "$chain"'\'' EXIT
  cat >"$chain"
  export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt
  VAULT_TOKEN="$(cat /tmp/.vt)"; export VAULT_TOKEN
  vault write pki_int_next/intermediate/set-signed certificate=@"$chain" >/dev/null
' <"$CHAIN"

allowed_domains='chaos-mesh-controller-manager,chaos-mesh-controller-manager.chaos-mesh,chaos-mesh-controller-manager.chaos-mesh.svc,chaos-daemon.chaos-mesh.org,controller-manager.chaos-mesh.org,localhost'
for team in ggg nmg khb ljw oje; do
  docker exec vault sh -ceu '
    export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt
    VAULT_TOKEN="$(cat /tmp/.vt)"; export VAULT_TOKEN
    vault write "pki_int_next/roles/${1}-internal-next" \
      allowed_domains="$2" allow_bare_domains=true allow_subdomains=false \
      allow_glob_domains=false allow_wildcard_certificates=false allow_any_name=false \
      enforce_hostnames=true allow_localhost=true allow_ip_sans=false require_cn=false \
      use_csr_common_name=false use_csr_sans=true key_type=rsa key_bits=2048 \
      server_flag=true client_flag=true code_signing_flag=false \
      email_protection_flag=false ttl=2160h max_ttl=2160h >/dev/null
  ' sh "$team" "$allowed_domains"
  cat <<POLICY | docker exec -i vault sh -ceu '
    export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt
    VAULT_TOKEN="$(cat /tmp/.vt)"; export VAULT_TOKEN
    vault policy write "$1" - >/dev/null
  ' sh "cert-manager-${team}-next"
path "pki_int_next/sign/${team}-internal-next" {
  capabilities = ["update"]
}
POLICY
  docker exec vault sh -ceu '
    export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt
    VAULT_TOKEN="$(cat /tmp/.vt)"; export VAULT_TOKEN
    vault write "auth/kubernetes-${1}/role/cert-manager-${1}-next" \
      bound_service_account_names=vault-issuer \
      bound_service_account_namespaces=cert-manager \
      audience=vault://vault-internal \
      token_policies="cert-manager-${1}-next" token_ttl=1m token_max_ttl=5m \
      token_no_default_policy=true token_type=batch >/dev/null
  ' sh "$team"
done
rm -f -- "$ROOT_FROM_CHAIN" "$INTERMEDIATE_FROM_CHAIN"
```

### Intermediate GitOps issuer/canary와 cutover

다음 단계는 `acer-argocd`의 cert-manager/Certificate 계획이 이미 배포된 뒤에만 한다.
Kubernetes object를 `apply`/`patch`하지 않고 검토 branch와 MR로 desired state를 바꾼다.

```bash
set -euo pipefail
ARGOCD_REPO="$HOME/acer-argocd"
test -f "$ARGOCD_REPO/apps/vault-pki.yaml"
test -f "$ARGOCD_REPO/apps/chaos-mesh-certificates.yaml"
ISSUER_BRANCH="feat/intermediate-rotation-$(date -u +%Y%m%d)"
git -C "$ARGOCD_REPO" switch main
git -C "$ARGOCD_REPO" pull --ff-only
git -C "$ARGOCD_REPO" switch -c "$ISSUER_BRANCH"
for team in ggg nmg khb ljw oje; do
  src="$ARGOCD_REPO/security/cert-manager/${team}/clusterissuer.yaml"
  dst="$ARGOCD_REPO/security/cert-manager/${team}/clusterissuer-next.yaml"
  test -f "$src"; test ! -e "$dst"
  sed \
    -e 's/name: vault-internal$/name: vault-internal-next/' \
    -e "s#pki_int/sign/${team}-internal#pki_int_next/sign/${team}-internal-next#" \
    -e "s/role: cert-manager-${team}$/role: cert-manager-${team}-next/" \
    "$src" >"$dst"
  grep -Fq 'name: vault-internal-next' "$dst"
  grep -Fq "path: pki_int_next/sign/${team}-internal-next" "$dst"
  grep -Fq "role: cert-manager-${team}-next" "$dst"
  kustomization="$ARGOCD_REPO/security/cert-manager/${team}/kustomization.yaml"
  grep -Fq 'clusterissuer-next.yaml' "$kustomization" || \
    printf '  - clusterissuer-next.yaml\n' >>"$kustomization"
done
CANARY="$ARGOCD_REPO/security/chaos-mesh-certificates/base/rotation-canary.yaml"
cat >"$CANARY" <<'YAML'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: rotation-canary
  namespace: chaos-mesh
spec:
  secretName: rotation-canary-next
  duration: 2160h
  renewBefore: 720h
  privateKey:
    algorithm: RSA
    size: 2048
    rotationPolicy: Always
  dnsNames: [localhost]
  usages: [client auth]
  issuerRef:
    name: vault-internal-next
    kind: ClusterIssuer
    group: cert-manager.io
YAML
CERT_KUSTOMIZATION="$ARGOCD_REPO/security/chaos-mesh-certificates/base/kustomization.yaml"
grep -Fq 'rotation-canary.yaml' "$CERT_KUSTOMIZATION" || \
  printf '  - rotation-canary.yaml\n' >>"$CERT_KUSTOMIZATION"
git -C "$ARGOCD_REPO" diff --check
git -C "$ARGOCD_REPO" add apps/vault-pki.yaml apps/chaos-mesh-certificates.yaml \
  security/cert-manager security/chaos-mesh-certificates/base
git -C "$ARGOCD_REPO" diff --cached --check
# 저장소 AGENTS.md의 commit/push/MR 승인을 받은 뒤에만 다음 두 명령을 실행한다.
git -C "$ARGOCD_REPO" commit -m 'feat(pki): 차기 Intermediate issuer와 canary 추가'
git -C "$ARGOCD_REPO" push -u origin "$ISSUER_BRANCH"
```

MR merge 뒤 Argo CD가 Git revision을 보게 한 후 issuer와 canary를 읽기 전용 명령으로
검증한다. 모든 팀의 `chaos-pki` 상태가 `prepare|enabled`여서 Certificate Application이
존재하는지도 먼저 확인한다.

```bash
set -euo pipefail
for team in ggg nmg khb ljw oje; do
  argocd app sync "vault-pki-${team}"
  argocd app wait "vault-pki-${team}" --health --sync --timeout 600
  argocd app sync "chaos-mesh-certificates-${team}"
  argocd app wait "chaos-mesh-certificates-${team}" --health --sync --timeout 600
  kubectl --context "$team" wait --for=condition=Ready clusterissuer/vault-internal-next \
    --timeout=300s
  kubectl --context "$team" -n chaos-mesh wait --for=condition=Ready \
    certificate/rotation-canary --timeout=300s
done
```

canary가 모두 Ready가 된 뒤 별도 cutover MR에서 네 Certificate의 issuerRef만 바꾼다.

```bash
set -euo pipefail
ARGOCD_REPO="$HOME/acer-argocd"
CUTOVER_BRANCH="feat/intermediate-cutover-$(date -u +%Y%m%d)"
git -C "$ARGOCD_REPO" switch main
git -C "$ARGOCD_REPO" pull --ff-only
git -C "$ARGOCD_REPO" switch -c "$CUTOVER_BRANCH"
CERTIFICATES="$ARGOCD_REPO/security/chaos-mesh-certificates/base/certificates.yaml"
sed -i '/issuerRef:/,/group: cert-manager.io/{s/name: vault-internal$/name: vault-internal-next/;}' \
  "$CERTIFICATES"
[[ "$(grep -Fc 'name: vault-internal-next' "$CERTIFICATES")" -eq 4 ]]
git -C "$ARGOCD_REPO" diff --check
git -C "$ARGOCD_REPO" add security/chaos-mesh-certificates/base/certificates.yaml
git -C "$ARGOCD_REPO" commit -m 'feat(pki): Chaos Mesh를 차기 Intermediate로 전환'
git -C "$ARGOCD_REPO" push -u origin "$CUTOVER_BRANCH"
CUTOVER_COMMIT="$(git -C "$ARGOCD_REPO" rev-parse HEAD)"
printf 'cutover_commit=%s cutover_epoch=%s\n' "$CUTOVER_COMMIT" "$(date -u +%s)" \
  >"$HOME/intermediate-cutover-public-evidence.txt"
```

MR merge 뒤 새 Secret/Pod 재적용을 확인한다. cutover rollback은 old issuer가 남아 있는
동안 새 branch에서 원 cutover commit을 revert하고 MR merge/sync하는 것이다.

```bash
for team in ggg nmg khb ljw oje; do
  argocd app sync "chaos-mesh-certificates-${team}"
  argocd app wait "chaos-mesh-certificates-${team}" --health --sync --timeout 600
done
# rollback이 필요할 때만, 저장소 승인을 받은 branch에서 실행한다.
git -C "$ARGOCD_REPO" switch -c "revert/intermediate-cutover-$(date -u +%Y%m%d)" main
git -C "$ARGOCD_REPO" revert "$CUTOVER_COMMIT"
git -C "$ARGOCD_REPO" push -u origin HEAD
```

### Intermediate overlap 증명과 별도 retirement 승인

최소 overlap은 leaf 최대 TTL 90일과 rollback 관찰 30일의 합인 120일이다. 그 이후
모든 Vault 내부 Certificate Secret의 leaf가 새 Intermediate로 검증되고 old
Intermediate로는 검증되지 않아야 한다.

```bash
set -euo pipefail
LEAF_TTL_SECONDS=$((90 * 24 * 60 * 60))
ROLLBACK_WINDOW_SECONDS=$((30 * 24 * 60 * 60))
MIN_OVERLAP_SECONDS=$((LEAF_TTL_SECONDS + ROLLBACK_WINDOW_SECONDS))
CUTOVER_EPOCH="$(sed -n 's/.*cutover_epoch=\([0-9]*\).*/\1/p' \
  "$HOME/intermediate-cutover-public-evidence.txt")"
ELAPSED_OVERLAP_SECONDS=$(($(date -u +%s) - CUTOVER_EPOCH))
[[ "$ELAPSED_OVERLAP_SECONDS" -ge "$MIN_OVERLAP_SECONDS" ]]
VERIFY_DIR="$(mktemp -d "$HOME/intermediate-retirement-XXXXXXXX")"
trap 'find "$VERIFY_DIR" -xdev -depth -delete' EXIT
OLD_ROOT="$ARGOCD_REPO/security/cert-manager/base/root-ca.crt"
OLD_INTERMEDIATE="$VERIFY_DIR/old-intermediate.pem"
NEW_INTERMEDIATE="$VERIFY_DIR/new-intermediate.pem"
docker exec vault sh -ceu '
  export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt
  VAULT_TOKEN="$(cat /tmp/.vt)"; export VAULT_TOKEN
  vault read -field=certificate pki_int/cert/ca
' >"$OLD_INTERMEDIATE"
docker exec vault sh -ceu '
  export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt
  VAULT_TOKEN="$(cat /tmp/.vt)"; export VAULT_TOKEN
  vault read -field=certificate pki_int_next/cert/ca
' >"$NEW_INTERMEDIATE"
OLD_ISSUED_LEAVES=0
for team in ggg nmg khb ljw oje; do
  while IFS=$'\t' read -r namespace secret; do
    bundle="$VERIFY_DIR/${team}-${namespace}-${secret}.pem"
    leaf="$bundle.leaf"
    kubectl --context "$team" -n "$namespace" get secret "$secret" \
      -o jsonpath='{.data.tls\.crt}' | base64 -d >"$bundle"
    openssl x509 -in "$bundle" -out "$leaf"
    openssl verify -CAfile "$OLD_ROOT" -untrusted "$NEW_INTERMEDIATE" "$leaf" >/dev/null
    if openssl verify -CAfile "$OLD_ROOT" -untrusted "$OLD_INTERMEDIATE" "$leaf" \
      >/dev/null 2>&1; then
      OLD_ISSUED_LEAVES=$((OLD_ISSUED_LEAVES + 1))
    fi
  done < <(kubectl --context "$team" get certificates -A -o json | jq -r '
    .items[] | select(.spec.issuerRef.name | startswith("vault-internal")) |
    [.metadata.namespace,.spec.secretName] | @tsv')
done
[[ "$OLD_ISSUED_LEAVES" -eq 0 ]]
read -rp 'old Intermediate retirement 승인 시 RETIREMENT APPROVED 입력: ' RETIREMENT_APPROVAL
[[ "$RETIREMENT_APPROVAL" == 'RETIREMENT APPROVED' ]]
unset RETIREMENT_APPROVAL
```

이 gate 뒤 old issuer manifest/auth policy/mount 제거는 별도 Git MR과 Vault 변경 승인을
받는다. 제거 전 snapshot과 isolated restore PASS를 다시 남긴다. retirement 이후에는
old 경로 rollback이 불가능하므로, 위 증거와 두 사람 승인이 없으면 실행하지 않는다.

1. 최신 snapshot과 isolated restore PASS를 확인한다.
2. `pki_int_next/`에 RSA 3072 non-exportable key/CSR을 만들고 offline Root로 1095일
   SHA-384 서명한다. 기존 `pki_int/` private key는 그대로 둔다.
3. `pki_int_next/intermediate/set-signed`로 검증된 leaf-first chain을 설치한다.
4. 다섯 팀에 `*-internal-next` PKI role, 별도 `cert-manager-*-next` policy/auth role을
   만든다. 기존 role/policy를 덮어쓰지 않는다.
5. Git/Argo CD로 `vault-internal-next` ClusterIssuer를 추가하고 canary Certificate를
   발급한다. Root가 같아도 old/new issuer를 최소 한 leaf TTL 동안 겹쳐 둔다.
6. canary의 chain, Ready, workload reload를 확인한 뒤 Certificate의 `issuerRef`를
   cluster별로 전환한다. 이전 issuer가 유효한 동안 rollback 가능해야 한다.
7. 모든 leaf가 새 serial/issuer로 갱신되고 90일 + 30일 rollback window가 지난 뒤에만
   old ClusterIssuer와 old auth/policy/mount를 별도 승인으로 폐기한다.

전환 중 오류가 나면 Certificate `issuerRef`를 `vault-internal`로 되돌리고 Argo CD를
sync한다. old issuer, old mount, 기존 trust bundle을 제거하지 않았으므로 즉시 rollback
할 수 있다. 새 mount 삭제는 실패 원인과 snapshot을 보존한 뒤 별도 승인한다.

## 7. Root 교체: 만료 2년 전 시작

Root 만료 2년 전 새 offline Root를 1~2절과 동일한 새 암호화 session에서 만들고,
Vaultwarden 별도 item과 두 번째 장비 복구 증명을 먼저 완료한다. 기존 Root item을
덮어쓰지 않는다. 시작 gate는 최신 snapshot checksum, 격리 restore PASS, 새 Root의
두 번째 장비 recovery PASS다.

### 새 Root와 `pki_int_newroot` 생성/설치

offline 장비에서 새 Root를 만들고 기계 검증한 뒤 Vault에는 새 non-exportable
Intermediate CSR만 만든다.

```bash
set -euo pipefail
umask 077
REPO="$HOME/acer-mgmt"
NEW_ROOT_BASE="$HOME/offline-ca/new-root-$(date -u +%Y%m%d)"
mkdir -p -m 700 "$NEW_ROOT_BASE"
NEW_ROOT_PASS="$(mktemp "$NEW_ROOT_BASE/.pass-XXXXXXXX")"
read -rsp '새 Root passphrase: ' NEW_ROOT_PASSPHRASE; printf '\n'
printf '%s' "$NEW_ROOT_PASSPHRASE" >"$NEW_ROOT_PASS"; unset NEW_ROOT_PASSPHRASE
ROOT_CA_PASS_FILE="$NEW_ROOT_PASS" \
  "$REPO/compose/scripts/create-offline-root-ca.sh" "$NEW_ROOT_BASE/root"
"$REPO/compose/scripts/verify-vault-pki-artifacts.sh" --root-only \
  "$NEW_ROOT_BASE/root/root-ca.crt" "$NEW_ROOT_BASE/root/root-ca.sha256"
# 2절과 동일하게 네 항목을 새 Vaultwarden item에 넣고 두 번째 장비에서 recovery한다.
```

mgmt Vault에서 별도 mount/key를 만들고 CSR만 offline 장비로 전달한다.

```bash
set -euo pipefail
umask 077
NEWROOT_WORK="$(mktemp -d "$HOME/vault-newroot-XXXXXXXX")"
docker exec vault sh -ceu '
  export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt
  VAULT_TOKEN="$(cat /tmp/.vt)"; export VAULT_TOKEN
  vault secrets enable -path=pki_int_newroot pki
  vault secrets tune -max-lease-ttl=26280h pki_int_newroot
  vault write -format=json pki_int_newroot/intermediate/generate/internal \
    common_name="Acer Lab Intermediate CA new Root" key_type=rsa key_bits=3072 \
    exclude_cn_from_sans=true
' | jq -er '.data.csr' >"$NEWROOT_WORK/vault-intermediate-newroot.csr"
openssl req -in "$NEWROOT_WORK/vault-intermediate-newroot.csr" -noout -verify -text |
  grep -F 'Public-Key: (3072 bit)'
```

offline 장비에서 CSR을 새 Root로 서명하고 full verifier를 통과시킨다.

```bash
set -euo pipefail
ROOT_CA_PASS_FILE="$NEW_ROOT_PASS" \
  "$REPO/compose/scripts/sign-vault-intermediate.sh" \
  "$NEW_ROOT_BASE/root" "$NEW_ROOT_BASE/vault-intermediate-newroot.csr" \
  "$NEW_ROOT_BASE/signed-newroot"
"$REPO/compose/scripts/verify-vault-pki-artifacts.sh" \
  "$NEW_ROOT_BASE/root/root-ca.crt" "$NEW_ROOT_BASE/root/root-ca.sha256" \
  "$NEW_ROOT_BASE/signed-newroot/vault-intermediate.crt" \
  "$NEW_ROOT_BASE/signed-newroot/vault-intermediate-chain.pem"
```

검증된 공개 chain만 mgmt의 `$NEWROOT_WORK/chain.pem`으로 돌려보내 설치하고 새
mount 전용 팀 경계를 만든다.

```bash
set -euo pipefail
CHAIN="$NEWROOT_WORK/chain.pem"
docker exec -i vault sh -ceu '
  umask 077; chain="$(mktemp /tmp/newroot-chain.XXXXXXXX)"
  trap '\''rm -f "$chain"'\'' EXIT; cat >"$chain"
  export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt
  VAULT_TOKEN="$(cat /tmp/.vt)"; export VAULT_TOKEN
  vault write pki_int_newroot/intermediate/set-signed certificate=@"$chain" >/dev/null
' <"$CHAIN"
allowed_domains='chaos-mesh-controller-manager,chaos-mesh-controller-manager.chaos-mesh,chaos-mesh-controller-manager.chaos-mesh.svc,chaos-daemon.chaos-mesh.org,controller-manager.chaos-mesh.org,localhost'
for team in ggg nmg khb ljw oje; do
  docker exec vault sh -ceu '
    export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt
    VAULT_TOKEN="$(cat /tmp/.vt)"; export VAULT_TOKEN
    vault write "pki_int_newroot/roles/${1}-internal-newroot" \
      allowed_domains="$2" allow_bare_domains=true allow_subdomains=false \
      allow_glob_domains=false allow_wildcard_certificates=false allow_any_name=false \
      enforce_hostnames=true allow_localhost=true allow_ip_sans=false require_cn=false \
      use_csr_common_name=false use_csr_sans=true key_type=rsa key_bits=2048 \
      server_flag=true client_flag=true code_signing_flag=false \
      email_protection_flag=false ttl=2160h max_ttl=2160h >/dev/null
  ' sh "$team" "$allowed_domains"
  cat <<POLICY | docker exec -i vault sh -ceu '
    export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt
    VAULT_TOKEN="$(cat /tmp/.vt)"; export VAULT_TOKEN
    vault policy write "$1" - >/dev/null
  ' sh "cert-manager-${team}-newroot"
path "pki_int_newroot/sign/${team}-internal-newroot" {
  capabilities = ["update"]
}
POLICY
  docker exec vault sh -ceu '
    export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt
    VAULT_TOKEN="$(cat /tmp/.vt)"; export VAULT_TOKEN
    vault write "auth/kubernetes-${1}/role/cert-manager-${1}-newroot" \
      bound_service_account_names=vault-issuer \
      bound_service_account_namespaces=cert-manager audience=vault://vault-internal \
      token_policies="cert-manager-${1}-newroot" token_ttl=1m token_max_ttl=5m \
      token_no_default_policy=true token_type=batch >/dev/null
  ' sh "$team"
done
```

### Root dual trust bundle, issuer/canary, cutover

Root dual trust bundle은 old Root가 먼저, new Root가 다음인 정확히 두 PEM block으로
Git에 넣는다. issuer와 canary도 같은 MR에서 추가하며 Kubernetes에 직접 쓰지 않는다.

```bash
set -euo pipefail
ARGOCD_REPO="$HOME/acer-argocd"
ROOT_BRANCH="feat/root-dual-trust-$(date -u +%Y%m%d)"
git -C "$ARGOCD_REPO" switch main
git -C "$ARGOCD_REPO" pull --ff-only
git -C "$ARGOCD_REPO" switch -c "$ROOT_BRANCH"
TRUST_BUNDLE="$ARGOCD_REPO/security/cert-manager/base/root-ca.crt"
ROOT_EVIDENCE_DIR="$HOME/root-rotation-public"
install -d -m 700 "$ROOT_EVIDENCE_DIR"
OLD_ROOT_COPY="$ROOT_EVIDENCE_DIR/old-root.crt"
NEW_ROOT_COPY="$ROOT_EVIDENCE_DIR/new-root.crt"
cp -- "$TRUST_BUNDLE" "$OLD_ROOT_COPY"
cp -- "$NEW_ROOT_BASE/root/root-ca.crt" "$NEW_ROOT_COPY"
chmod 644 "$OLD_ROOT_COPY" "$NEW_ROOT_COPY"
cat "$OLD_ROOT_COPY" "$NEW_ROOT_COPY" >"$TRUST_BUNDLE"
[[ "$(grep -Fc -- '-----BEGIN CERTIFICATE-----' "$TRUST_BUNDLE")" -eq 2 ]]
openssl verify -check_ss_sig -CAfile "$OLD_ROOT_COPY" "$OLD_ROOT_COPY"
openssl verify -check_ss_sig -CAfile "$NEW_ROOT_BASE/root/root-ca.crt" \
  "$NEW_ROOT_BASE/root/root-ca.crt"
for team in ggg nmg khb ljw oje; do
  src="$ARGOCD_REPO/security/cert-manager/${team}/clusterissuer.yaml"
  dst="$ARGOCD_REPO/security/cert-manager/${team}/clusterissuer-newroot.yaml"
  sed \
    -e 's/name: vault-internal$/name: vault-internal-newroot/' \
    -e "s#pki_int/sign/${team}-internal#pki_int_newroot/sign/${team}-internal-newroot#" \
    -e "s/role: cert-manager-${team}$/role: cert-manager-${team}-newroot/" \
    "$src" >"$dst"
  printf '  - clusterissuer-newroot.yaml\n' >> \
    "$ARGOCD_REPO/security/cert-manager/${team}/kustomization.yaml"
done
sed -i 's/name: vault-internal-next$/name: vault-internal-newroot/' \
  "$ARGOCD_REPO/security/chaos-mesh-certificates/base/rotation-canary.yaml"
git -C "$ARGOCD_REPO" diff --check
git -C "$ARGOCD_REPO" add security/cert-manager security/chaos-mesh-certificates/base/rotation-canary.yaml
git -C "$ARGOCD_REPO" commit -m 'feat(pki): 새 Root dual trust와 issuer 추가'
git -C "$ARGOCD_REPO" push -u origin "$ROOT_BRANCH"
```

MR merge 뒤 모든 issuer/canary가 Ready인지 확인한다.

```bash
for team in ggg nmg khb ljw oje; do
  argocd app sync "vault-pki-${team}"
  argocd app wait "vault-pki-${team}" --health --sync --timeout 600
  kubectl --context "$team" wait --for=condition=Ready \
    clusterissuer/vault-internal-newroot --timeout=300s
  argocd app sync "chaos-mesh-certificates-${team}"
  kubectl --context "$team" -n chaos-mesh wait --for=condition=Ready \
    certificate/rotation-canary --timeout=300s
done
```

별도 cutover branch에서 네 Certificate를 새 Root issuer로 전환하고 MR로 병합한다.

```bash
ROOT_CUTOVER_BRANCH="feat/root-cutover-$(date -u +%Y%m%d)"
git -C "$ARGOCD_REPO" switch main
git -C "$ARGOCD_REPO" pull --ff-only
git -C "$ARGOCD_REPO" switch -c "$ROOT_CUTOVER_BRANCH"
CERTIFICATES="$ARGOCD_REPO/security/chaos-mesh-certificates/base/certificates.yaml"
sed -i '/issuerRef:/,/group: cert-manager.io/{s/name: vault-internal-next$/name: vault-internal-newroot/;}' \
  "$CERTIFICATES"
[[ "$(grep -Fc 'name: vault-internal-newroot' "$CERTIFICATES")" -eq 4 ]]
git -C "$ARGOCD_REPO" diff --check
git -C "$ARGOCD_REPO" add security/chaos-mesh-certificates/base/certificates.yaml
git -C "$ARGOCD_REPO" commit -m 'feat(pki): Chaos Mesh를 새 Root issuer로 전환'
git -C "$ARGOCD_REPO" push -u origin "$ROOT_CUTOVER_BRANCH"
ROOT_CUTOVER_COMMIT="$(git -C "$ARGOCD_REPO" rev-parse HEAD)"
printf 'cutover_commit=%s cutover_epoch=%s\n' "$ROOT_CUTOVER_COMMIT" "$(date -u +%s)" \
  >"$HOME/root-cutover-public-evidence.txt"
```

문제가 있으면 old+new trust bundle과 old issuer가 남아 있는 동안 Git revert MR로
되돌린다.

```bash
git -C "$ARGOCD_REPO" switch -c "revert/root-cutover-$(date -u +%Y%m%d)" main
git -C "$ARGOCD_REPO" revert "$ROOT_CUTOVER_COMMIT"
git -C "$ARGOCD_REPO" push -u origin HEAD
```

### Root retirement gate

Intermediate와 동일하게 120일 overlap을 계산하고 모든 내부 leaf를 검사한다. 새
Root/Intermediate 검증은 모두 성공하고 old Root/Intermediate 검증은 하나도 성공하면
안 된다.

```bash
LEAF_TTL_SECONDS=$((90 * 24 * 60 * 60))
ROLLBACK_WINDOW_SECONDS=$((30 * 24 * 60 * 60))
MIN_OVERLAP_SECONDS=$((LEAF_TTL_SECONDS + ROLLBACK_WINDOW_SECONDS))
ROOT_CUTOVER_EPOCH="$(sed -n 's/.*cutover_epoch=\([0-9]*\).*/\1/p' \
  "$HOME/root-cutover-public-evidence.txt")"
ELAPSED_OVERLAP_SECONDS=$(($(date -u +%s) - ROOT_CUTOVER_EPOCH))
[[ "$ELAPSED_OVERLAP_SECONDS" -ge "$MIN_OVERLAP_SECONDS" ]]
ROOT_EVIDENCE_DIR="$HOME/root-rotation-public"
VERIFY_DIR="$(mktemp -d "$HOME/root-retirement-XXXXXXXX")"
trap 'find "$VERIFY_DIR" -xdev -depth -delete' EXIT
OLD_ROOT="$ROOT_EVIDENCE_DIR/old-root.crt"
NEW_ROOT="$ROOT_EVIDENCE_DIR/new-root.crt"
OLD_INTERMEDIATE="$VERIFY_DIR/old-intermediate.pem"
NEW_INTERMEDIATE="$VERIFY_DIR/newroot-intermediate.pem"
docker exec vault sh -ceu '
  export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt
  VAULT_TOKEN="$(cat /tmp/.vt)"; export VAULT_TOKEN
  vault read -field=certificate pki_int/cert/ca
' >"$OLD_INTERMEDIATE"
docker exec vault sh -ceu '
  export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt
  VAULT_TOKEN="$(cat /tmp/.vt)"; export VAULT_TOKEN
  vault read -field=certificate pki_int_newroot/cert/ca
' >"$NEW_INTERMEDIATE"
OLD_ISSUED_LEAVES=0
for team in ggg nmg khb ljw oje; do
  while IFS=$'\t' read -r namespace secret; do
    bundle="$VERIFY_DIR/root-${team}-${namespace}-${secret}.pem"
    leaf="$bundle.leaf"
    kubectl --context "$team" -n "$namespace" get secret "$secret" \
      -o jsonpath='{.data.tls\.crt}' | base64 -d >"$bundle"
    openssl x509 -in "$bundle" -out "$leaf"
    openssl verify -CAfile "$NEW_ROOT" -untrusted "$NEW_INTERMEDIATE" "$leaf" >/dev/null
    if openssl verify -CAfile "$OLD_ROOT" -untrusted "$OLD_INTERMEDIATE" "$leaf" \
      >/dev/null 2>&1; then OLD_ISSUED_LEAVES=$((OLD_ISSUED_LEAVES + 1)); fi
  done < <(kubectl --context "$team" get certificates -A -o json | jq -r '
    .items[] | select(.spec.issuerRef.name | startswith("vault-internal")) |
    [.metadata.namespace,.spec.secretName] | @tsv')
done
[[ "$OLD_ISSUED_LEAVES" -eq 0 ]]
read -rp 'old Root retirement 승인 시 RETIREMENT APPROVED 입력: ' RETIREMENT_APPROVAL
[[ "$RETIREMENT_APPROVAL" == 'RETIREMENT APPROVED' ]]
unset RETIREMENT_APPROVAL
```

이후에만 별도 MR로 `security/cert-manager/base/root-ca.crt`에서 old Root를 제거한다.
old issuer/mount/policy와 old Root 개인키 폐기도 별도 승인이다. retirement 전에는 항상
Git revert rollback을 유지하고, retirement 뒤에는 rollback이 불가능함을 승인 기록에
명시한다.

## 8. 경보별 사고 대응

### Vault sealed/unhealthy

Vault blackbox target `/v1/sys/health?standbyok=true&perfstandbyok=true`, `vault status`,
container health를 확인한다. sealed면 승인된 보관소에서 threshold 수만큼 unseal key를
각 담당자가 terminal prompt로 제공한다. token/key를 Slack이나 incident log에 넣지
않는다. storage 손상이 의심되면 production에서 `restore -force`하지 말고 먼저 월간
격리 복구 절차로 snapshot을 검증한다.

### ClusterIssuerNotReady / CertificateNotReady

`kubectl -n cert-manager describe clusterissuer vault-internal`, Certificate 및
CertificateRequest 이벤트, cert-manager controller log를 확인한다. `vault-issuer`
ServiceAccount, audience `vault://vault-internal`, 팀 auth mount/role, Vault network와
seal 상태를 순서대로 확인한다. Secret data와 JWT를 출력하는 `kubectl get secret -o
yaml`은 사용하지 않는다.

### CertManagerVaultSyncErrors / 만료 경보

15분 controller 오류 증가가 어느 cluster/controller에서 발생했는지 확인하고,
CertificateRequest의 reason과 Vault audit의 path/status만 대조한다. leaf 만료 30/14/7일
tier는 겹치지 않으며 expired 표본은 Ready 경보로 대응한다. 임시 self-signed 인증서나
수동 Secret patch로 우회하지 않는다.

### VaultRaftSnapshotStale

`systemctl status acer-mgmt-db-backup.service`, journal, Vault seal 상태, 최신 로컬
`SHA256SUMS`/`inspect.txt`, MinIO `db-backup/vault-raft/daily/`를 확인한다. snapshot이
정상이면 service를 한 번 재실행하고 timestamp metric 갱신을 확인한다. 실패 산출물을
성공 경로로 복사하거나 성공 metric을 수동으로 조작하지 않는다.

### Offsite encryption preflight 실패

`mc encrypt info`가 SSE-S3 또는 SSE-KMS를 증명하지 못하면 mirror가 fail-closed하는
것이 정상이다. backup job에 bucket 설정 권한을 추가하지 않는다. AWS bucket default
encryption을 별도 승인/계정으로 설정하고 `mc encrypt info`를 다시 검증한 다음 offsite
job을 재실행한다.
