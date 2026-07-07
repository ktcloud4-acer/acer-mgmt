# ELK 로그 스택 (Elasticsearch + Logstash + Kibana)

팀 k8s 클러스터(ggg/khb/ljw/nmg/oje) + mgmt 자체 로그를 중앙 수집·시각화한다.
수집 경로: **각 클러스터 Filebeat DaemonSet → (tailnet) Logstash:5044 → Elasticsearch → Kibana**.
(Filebeat 매니페스트는 `acer-argocd` 저장소 `logging/` 에서 GitOps 로 배포한다.)

## 인덱스 라우팅 (Logstash `config/pipeline/90-outputs.conf`)

| log_type | 인덱스 |
|----------|--------|
| `k8s`    | `k8s-logs-<user>-YYYY.MM.dd` |
| `infra`  | `infra-logs-<user>-YYYY.MM.dd` |
| (그 외)  | `service-logs-mgmt-v2-YYYY.MM.dd` |

`<user>` = 테넌트 식별자(팀원 클러스터명). Filebeat 가 `fields.user` 로 주입.

## 보존정책 / 시각화 프로비저닝 — `scripts/apply-observability.sh`

mgmt 호스트에서 실행. **idempotent** 하므로 반복 실행 안전.

```bash
bash compose/stacks/observability/elk/scripts/apply-observability.sh
# ES/Kibana 주소 오버라이드: ES=http://... KB=http://... bash ...
```

적용 내용:

1. **ILM 정책 `logs-retention-14d`** (`config/ilm/logs-retention-14d.policy.json`)
   — 인덱스 생성 **14일 후 자동 삭제**. 보존 기간 변경은 이 파일의 `min_age` 만 수정 후 재실행.
2. **인덱스 템플릿 `acer-logs`** (`config/ilm/acer-logs.template.json`)
   — `k8s-logs-*`, `infra-logs-*` 신규 인덱스에 `number_of_replicas: 0`(단일노드 → green) + 위 ILM 자동 부착.
3. **기존 인덱스 보정** — 이미 존재하는 `k8s-logs-*`/`infra-logs-*` 에 replica0 + ILM 소급 적용.
4. **Kibana 팀원별 Space** (`ggg`/`khb`/`ljw`/`nmg`/`oje`) + Space별 **data view**
   (`k8s-logs-<user>-*`, `infra-logs-<user>-*`) + **`errors` 저장검색**(ERROR/FATAL/CRITICAL).
   default(admin) Space 에는 전체 조회용 `k8s-logs-*,infra-logs-*` / `service-logs-mgmt-*` data view.

## ⚠️ 보안 주의 — Space 는 접근제어가 아니다

이 스택은 `compose.yaml` 에서 `xpack.security.enabled: false` 다. 따라서 Kibana Space 는
**조직적(화면) 분리**일 뿐 **접근 제어가 아니며**, 누구나 우상단에서 Space 를 전환해 타 팀
로그를 볼 수 있다. 팀원별 진짜 격리가 필요하면 `xpack.security` 활성화 + role/space 권한
매핑이 별도로 필요하다(ES 비밀번호·Logstash/Kibana 인증 재구성 수반).

## 미적용/후속 과제

- `service-logs-mgmt-v2-*` (mgmt 자체 도커 로그)는 하루 수 GB 규모인데 **보존정책 미부착**이다.
  필요 시 동일 ILM 을 붙이거나 노이즈 소스를 에이전트단에서 드롭할 것.
- 대량 유입 시 `Filebeat → Kafka → Logstash → ES` 버퍼링(이미 운영 중인 Kafka 활용) 고려.
