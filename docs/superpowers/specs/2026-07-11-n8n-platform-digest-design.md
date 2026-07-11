# n8n 전 팀 운영 다이제스트 설계

## 목적

mgmt에 n8n을 독립 Compose 서비스로 운영하고, 중앙 Prometheus에 이미
remote-write된 관측 데이터를 이용해 매일 및 필요 시 수동으로 전 팀 운영
상태를 Slack에 요약한다.

대상은 mgmt와 `ggg`, `khb`, `ljw`, `nmg`, `oje` 클러스터다. 이 첫 번째
워크플로는 read-only Prometheus API만 사용하며, Kubernetes API, OpenStack
API, SSH, Docker socket에 접근하지 않는다.

## 선택한 접근

`Schedule Trigger`와 `Manual Trigger`가 하나의 공통 워크플로를 시작한다.
워크플로는 mgmt-proxy 네트워크의 `prometheus:9090`에 PromQL을 요청하고,
요약을 만든 뒤 기존 infra Slack webhook으로 메시지를 전송한다.

다른 선택지였던 클러스터별 Kubernetes API 직접 조회는 Event와 Velero
상태를 가져올 수 있지만, n8n에 다섯 개 클러스터의 별도 credential을
배포해야 한다. host SSH 조회는 현재 필요한 데이터가 이미 Prometheus에
있고 접근 경로도 별도이므로 제외한다.

## 구성

### n8n 스택

새 스택은 `compose/stacks/observability/n8n/`에 둔다.

- `n8n`: `docker.n8n.io/n8nio/n8n`의 고정 stable 버전을 사용한다.
- `n8n-db`: 이 서비스만 사용하는 PostgreSQL 데이터베이스와 계정이다.
- 데이터는 `${DATA_ROOT:-/home/mgmt-data}/n8n`에 저장한다.
- n8n만 `mgmt-proxy`에 연결한다. PostgreSQL은 프로젝트 내부 네트워크에만
  남기며 포트를 publish하지 않는다.
- UI는 `n8n.${BASE_DOMAIN}`으로 Traefik이 TLS를 종료하고 OAuth2 Proxy
  forward-auth와 기존 secure header middleware를 적용한다.
- n8n은 `Asia/Seoul` 시간대와 명시적인 `WEBHOOK_URL`을 사용한다.
- health endpoint와 `unless-stopped` 재시작 정책을 둔다.

### 시크릿과 권한

Vault Agent가 `/home/mgmt-data/vault-agent/secrets/n8n.env`를 렌더링한다.
이 파일에는 다음 값만 포함한다.

- `N8N_ENCRYPTION_KEY`
- `DB_POSTGRESDB_PASSWORD`
- `SLACK_WEBHOOK_INFRA`

Slack webhook은 기존 Grafana용 값을 참조한다. n8n은 Prometheus API에
인증 없이 내부 Docker DNS로 접근하며, Kubernetes credential, SSH key,
Docker socket mount를 받지 않는다.

### 다이제스트 워크플로

매일 09:05 `Asia/Seoul`에 실행하며, n8n 편집기의 수동 실행도 같은
요약을 보낸다. 대상 클러스터는 workflow의 상수 목록으로 고정한다.

각 실행은 다음을 조회한다.

1. 모든 firing alert와 severity
2. 클러스터별 remote-write 수집 신선도와 필수 scrape 상태
3. Ready node 수와 전체 node 수
4. Pending 또는 Failed Pod 수와 24시간 컨테이너 재시작 증가량
5. mgmt 호스트의 CPU, 메모리, 루트 디스크 사용률
6. 최근 24시간 중 `up == 0`이었던 대상

클러스터의 원본 시계열이 없거나 30분 이상 오래되면 `정상`이 아니라
`미수집`으로 표시한다. critical alert, 수집 공백, NotReady node, Failed
Pod는 조치 필요 영역에 먼저 놓는다. 그 밖의 상태는 한 줄짜리 클러스터
표로 전달한다.

Slack 전송이 실패하거나 워크플로 자체가 실패하면 별도 n8n error workflow가
같은 채널에 실패 시각과 실행 링크를 보낸다. 정상 실행 기록은 30일 또는
500건까지만 보존해 데이터베이스가 무한히 증가하지 않게 한다.

## 검증 기준

1. Compose 설정 검증이 통과하고 두 컨테이너가 healthy 상태가 된다.
2. UI는 Traefik HTTPS와 OAuth2 Proxy 보호를 통과해야 접근할 수 있다.
3. n8n 컨테이너에서 `prometheus:9090`의 query API에 연결할 수 있다.
4. workflow 수동 실행이 여섯 대상의 상태와 미수집 상태를 구분한 Slack
   메시지를 하나 전송한다.
5. schedule은 `Asia/Seoul` 09:05로 저장되어야 한다.
6. workflow에는 write-capable infrastructure credential이나 host mount가
   없어야 한다.

## 범위 밖

- 클러스터 Kubernetes API의 Event, Velero CRD, Argo CD 상세 상태
- acer-aio의 OpenStack API와 호스트 명령 실행
- n8n worker/Redis queue mode 및 고가용성 확장
- n8n을 통한 인프라 변경 자동화
