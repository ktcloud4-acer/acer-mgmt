# n8n 운영 다이제스트

이 스택은 중앙 Prometheus의 read-only API만 조회해 mgmt와 `ggg`, `khb`,
`ljw`, `nmg`, `oje`의 운영 상태를 Slack으로 요약한다. Kubernetes API,
OpenStack API, SSH 키, Docker socket은 이 스택에 제공하지 않는다.

## 시크릿

Vault KV `kv/mgmt/n8n`에 다음 두 값을 저장한다.

- `db_password`: n8n 전용 PostgreSQL 계정 비밀번호
- `encryption_key`: n8n credential 암호화 키

Vault Agent는 위 두 값과 기존 `kv/mgmt/grafana`의 infra Slack webhook을
`/home/mgmt-data/vault-agent/secrets/observability/n8n.env`로 렌더한다.
이 파일과 데이터 디렉터리는 Git에 커밋하지 않는다.

## 배포

```bash
cd /home/user1/acer-mgmt/compose
sudo install -d -o 1000 -g 1000 -m 0750 /home/mgmt-data/n8n/app
sudo install -d -o 999 -g 999 -m 0700 /home/mgmt-data/n8n/postgres
sudo restorecon -RFv /home/mgmt-data/n8n
docker compose --env-file ../.env \
  --env-file /home/mgmt-data/vault-agent/secrets/observability/n8n.env \
  -f stacks/observability/n8n/compose.yaml up -d
```

처음 기동한 뒤 `https://n8n.${BASE_DOMAIN}`에서 owner 계정을 만들고, 운영
다이제스트 workflow를 import한 뒤 활성화한다. UI 접근은 Traefik의
`secure-headers`와 OAuth2 Proxy `sso-auth` middleware를 모두 통과해야 한다.

## Workflow import

```bash
cd /home/user1/acer-mgmt/compose
./stacks/observability/n8n/scripts/import-workflows.sh
```

`ACER 전체 운영 다이제스트`는 매일 09:05 `Asia/Seoul`에 실행되고, n8n
편집기에서 수동 실행해도 같은 Slack 메시지를 생성한다. `ACER 운영
다이제스트 실패 알림`을 primary workflow의 Error Workflow로 지정한다.
