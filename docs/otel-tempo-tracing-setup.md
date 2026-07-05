# OTel Collector + Grafana Tempo 트레이싱 — 셋업 & 검증 runbook

기존 관측 3축 중 빠져 있던 **트레이스**를 채운다. 로그(ELK)·메트릭(Prometheus)과 동일한
토폴로지를 그대로 복제한다.

```
web-service(앱)   →   OTel Collector(클러스터별 1개)   →   Tempo(mgmt)
     (상위)                 (중간, = prometheus-agent 판)        (하위)
   OTLP gRPC            tailnet IP 100.117.59.96:4317        Grafana 로 조회
```

의존성은 단방향(App → Collector → Tempo). **하위는 상위를 몰라도 되므로 앱 재개발 전에
백엔드를 먼저 세워 놀려도 무방하다.** 실제로 가장 어려운 egress 경로를 앱 없이 먼저 검증할 수 있어 권장.

---

## 얼려둔 계약(contract)

앱과 백엔드가 합의하는 인터페이스. 바꾸면 양쪽을 같이 바꿔야 한다.

| 항목 | 값 |
|---|---|
| 클러스터 내 Collector 접속점 | `otel-collector.monitoring.svc.cluster.local:4317` |
| 프로토콜/포트 | OTLP **gRPC 4317** (HTTP 4318 도 수신) |
| Collector → Tempo | `100.117.59.96:4317` (mgmt tailnet IP, 평문) |
| resource attribute | 앱: `service.name`, `service.namespace`, `deployment.environment` / Collector: `cluster`, `k8s.cluster.name` |

---

## 파일 배치

**acer-mgmt (중앙, docker compose)**
- `compose/stacks/observability/tempo/compose.yaml` — Tempo. OTLP 4317/4318 host publish, 조회 3200 은 내부(Grafana)만.
- `compose/stacks/observability/tempo/config/tempo.yaml` — local 백엔드, 보존 14d.
- `compose/stacks/observability/grafana/provisioning/datasources/tempo.yaml` — Grafana Tempo datasource.

**acer-argocd (클러스터, GitOps)**
- `tracing/base/` — Collector Deployment/Service/RBAC (+ kustomization).
- `tracing/ggg/` — Collector ConfigMap(cluster=ggg 스탬프, load 드롭, tail sampling, Tempo export) + kustomization.
- `argocd/tracing-ggg-application.yaml` — Argo Application.
- `base/fastapi-deployment.yaml` — `OTEL_*` env 추가(계측 전엔 inert).

> 나머지 4개 클러스터(khb/ljw/nmg/oje)는 `tracing/ggg`·`tracing-ggg-application.yaml` 를 복제 후
> `cluster/user` 값과 `destination.server`(`<user>-operator.tailc0244b.ts.net`)만 바꾸면 된다.

---

## 배포 순서

### 1. Tempo 데이터 디렉터리 준비 (mgmt 호스트)
```bash
sudo mkdir -p /home/mgmt-data/tempo
sudo chown -R 10001:10001 /home/mgmt-data/tempo   # compose 의 user: 10001 과 일치
```

### 2. Tempo 기동 (mgmt)
```bash
cd compose/stacks/observability/tempo
docker compose up -d
docker compose logs -f tempo   # "Tempo started" / /ready 200 확인
```

### 3. Grafana 재기동으로 Tempo datasource provisioning 반영 (mgmt)
```bash
cd compose/stacks/observability/grafana
docker compose up -d --force-recreate
# Grafana → Connections → Data sources → Tempo "Test" 초록불 확인
```

### 4. Collector 배포 (클러스터, Argo)
```bash
kubectl apply -f argocd/tracing-ggg-application.yaml   # 또는 app-of-apps 에 편입
# Argo 에서 tracing-ggg Synced/Healthy 확인
kubectl -n monitoring rollout status deploy/otel-collector
```

---

## 검증 (telemetrygen — 앱 없이 경로 전체 확인)

### A. mgmt 호스트 → Tempo 직접 (수신부 확인)
```bash
docker run --rm --network host \
  ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
  traces --otlp-endpoint 127.0.0.1:4317 --otlp-insecure --traces 5 --service telemetrygen-local
```

### B. 클러스터 파드 → Collector → tailnet → Tempo (전체 경로 확인)
```bash
kubectl -n monitoring run telemetrygen --rm -i --restart=Never \
  --image=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest -- \
  traces --otlp-endpoint otel-collector.monitoring.svc.cluster.local:4317 \
  --otlp-insecure --traces 10 --service telemetrygen-ggg
```

### C. 조회
Grafana → Explore → **Tempo** → Search → Service Name `telemetrygen-ggg` 로 트레이스가 보이면 성공.
`cluster=ggg` resource attribute 도 함께 찍혀야 한다(Collector resource 프로세서 동작 확인).

> 실패 시 점검: ① `kubectl -n monitoring logs deploy/otel-collector` 에서 export 에러(연결 거부 = tailnet/포트),
> ② mgmt 에서 `ss -tlnp | grep 4317` (Tempo 가 host 에 publish 됐는지), ③ 클러스터 노드에서
> `nc -vz 100.117.59.96 4317` (tailnet 도달성 — prometheus 9090 과 동일 경로라 되면 정상).

---

## 앱 재개발 시 체크리스트 (데모 → 실서비스)

- [ ] `opentelemetry-instrumentation-fastapi` + `sqlalchemy`(+`psycopg`) **자동계측** 도입. 수동 미들웨어 대체.
- [ ] OTLP exporter 는 env(`OTEL_EXPORTER_OTLP_ENDPOINT`)만 읽게. **graceful degradation** — Collector 가 죽어도 export 만 실패하고 서비스는 계속.
- [ ] `log_event()` JSON 에 `trace_id`/`span_id` 주입 → 트레이스↔로그 상관관계 전제.
- [ ] **메트릭 라벨 카디널리티 버그 수정**: `HTTP_REQUESTS`/`HTTP_LATENCY` 가 `request.url.path`(원본) 대신
      **라우트 템플릿**(`/api/tasks/{task_id}`)을 쓰도록. 안 고치면 UUID 마다 시계열/ span name 폭발.
- [ ] (옵션) Prometheus histogram 에 exemplar(trace_id) → Grafana metric→trace 점프.

## 남은 결정 / 후속

- **로그↔트레이스**: Grafana 에 Elasticsearch datasource 추가 + `tracesToLogsV2` 로 trace_id 파생필드 연결(안 하면 Kibana 수동 검색).
- **스토리지**: 초기 local 디스크. 규모 커지면 `tempo.yaml` 의 storage 를 estate S3(MinIO/rustfs)로 전환.
- **metrics-generator**: `tempo.yaml` 주석 해제 시 span 기반 RED 메트릭 + service graph 를 mgmt Prometheus 로. 처음엔 off.
- **Collector 스케일**: tail_sampling 때문에 replicas: 1 유지. 확장하려면 load-balancing exporter 계층 필요.
