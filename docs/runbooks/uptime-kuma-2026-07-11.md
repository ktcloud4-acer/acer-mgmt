# Uptime Kuma 운영 런북

Uptime Kuma는 `acer-mgmt`에서 실행하는 운영자 전용 외부 관점 상태판이다.
호스트·Kubernetes 리소스·Pod 상태의 정답은 기존 Prometheus, node-exporter,
kube-state-metrics, prometheus-agent, Alertmanager에 남긴다.

## 보안 경계

- 접속 주소는 `https://kuma.${BASE_DOMAIN}`이며, Traefik의
  `sso-auth@file`로 Keycloak 인증을 먼저 적용한다.
- Kuma 첫 화면에서 만드는 로컬 관리자는 Kuma 내부 계정이다. 비밀번호나
  API 토큰을 Git, 쉘 이력, 런북에 저장하지 않는다.
- Docker 소켓과 직접 호스트 포트는 사용하지 않는다.
- 공개 Status Page는 만들지 않는다. 외부 공개 상태 페이지는 노출 범위를
  별도로 검토한 뒤 별도 변경으로 처리한다.

## 배포와 기본 검증

운영 호스트의 동기화된 저장소 checkout에서 실행한다.

```bash
docker compose --env-file .env \
  -f compose/stacks/observability/uptime-kuma/compose.yaml config >/dev/null
docker compose --env-file .env \
  -f compose/stacks/observability/uptime-kuma/compose.yaml up -d
sudo docker inspect uptime-kuma --format '{{.State.Health.Status}}'
```

`healthy`가 되면 `https://kuma.${BASE_DOMAIN}`에 SSO로 로그인하고, Kuma의
초기 로컬 관리자 설정을 완료한다. Uptime Kuma는 안정적인 공개 monitor
provisioning API를 제공하지 않으므로, 내부 SQLite 수정이나 비공식 Socket.IO
자동화 대신 아래 인벤토리를 UI에서 만든다.

공통 설정은 HTTP(s), 기대 상태 200, 간격 60초, 재시도 기본값으로 둔다.
Kuma 알림 제공자는 최초 배포에서 모두 비활성으로 둔다. Grafana,
Prometheus, Alertmanager는 기존 Blackbox Exporter와 Alertmanager가 공식
장애 알림을 담당하므로 Kuma에서 중복 페이지를 보내지 않는다.

## 모니터 인벤토리

### Management services

| 이름 | URL | 기대 상태 | 알림 |
|---|---|---:|---|
| Grafana health | `https://grafana.${BASE_DOMAIN}/api/health` | 200 | 비활성 |
| Prometheus health | `https://prometheus.${BASE_DOMAIN}/-/healthy` | 200 | 비활성 |
| Alertmanager | `https://alertmanager.${BASE_DOMAIN}/` | 200 | 비활성 |

### Team clusters

각 팀은 API 경로와 사용자 경로를 별도로 생성한다. API monitor는
`mgmt -> Tailscale Operator Proxy -> Kubernetes API` 관리 경로를, dashboard
monitor는 Cloudflare/Ingress를 거친 사용자 경로를 뜻한다.

| 팀 | API monitor | Dashboard monitor |
|---|---|---|
| NMG | `NMG Kubernetes API /livez` — `https://nmg-operator.tailc0244b.ts.net/livez` | `NMG ScaleCart dashboard` — `https://nmg.${BASE_DOMAIN}/` |
| GGG | `GGG Kubernetes API /livez` — `https://ggg-operator.tailc0244b.ts.net/livez` | `GGG ScaleCart dashboard` — `https://ggg.${BASE_DOMAIN}/` |
| OJE | `OJE Kubernetes API /livez` — `https://oje-operator.tailc0244b.ts.net/livez` | `OJE ScaleCart dashboard` — `https://oje.${BASE_DOMAIN}/` |
| KHB | `KHB Kubernetes API /livez` — `https://khb-operator.tailc0244b.ts.net/livez` | `KHB ScaleCart dashboard` — `https://khb.${BASE_DOMAIN}/` |
| LJW | `LJW Kubernetes API /livez` — `https://ljw-operator.tailc0244b.ts.net/livez` | `LJW ScaleCart dashboard` — `https://ljw.${BASE_DOMAIN}/` |

검증 시점에는 NMG와 GGG의 두 경로가 HTTP 200이었다. OJE, KHB, LJW는 API
`/livez`가 타임아웃이고 dashboard는 HTTP 530이었다. 해당 세 팀은 monitor를
삭제하거나 성공으로 우회하지 말고 Down으로 유지해 복구 시점을 표시한다.

## 결과 대조

Kuma 화면의 상태는 관리 호스트에서 얻은 직접 결과와 일치해야 한다.

```bash
for team in nmg ggg oje khb ljw; do
  curl -k -sS -o /dev/null -w "${team} API HTTP %{http_code} %{time_total}s\n" \
    --connect-timeout 12 "https://${team}-operator.tailc0244b.ts.net/livez" || true
  curl -k -sS -o /dev/null -w "${team} dashboard HTTP %{http_code} %{time_total}s\n" \
    --connect-timeout 12 "https://${team}.${BASE_DOMAIN}/" || true
done
```

Kuma의 Up/Down이 직접 요청과 다르면 Kuma 컨테이너 DNS·Tailscale egress·TLS를
확인한다. API와 dashboard가 동시에 Down이면 원격 클러스터/터널 상태를 먼저
조사한다. API만 Down이면 Operator Proxy 또는 Kubernetes control-plane 경로를,
dashboard만 Down이면 Cloudflare·Ingress·ScaleCart 배포 경로를 조사한다.

## 영속성, 백업, 롤백

데이터는 `${DATA_ROOT:-/home/mgmt-data}/uptime-kuma`의 로컬 SQLite 데이터에
저장된다. 이 경로는 기존 Restic의 `DATA_ROOT` 소스에 포함된다. 컨테이너를
재시작해도 monitor 정의와 기록이 남아야 한다.

```bash
docker compose --env-file .env \
  -f compose/stacks/observability/uptime-kuma/compose.yaml restart
```

롤백은 Kuma Compose service만 중지·제거하고, 데이터 디렉터리는 명시적인
삭제 승인이 있을 때까지 보존한다. Prometheus, Blackbox Exporter,
Alertmanager, OpenStack, Kubernetes 리소스는 롤백 대상이 아니다.
