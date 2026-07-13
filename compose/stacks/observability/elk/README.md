# ELK 로그 스택 (Elasticsearch + Logstash + Kibana)

팀 k8s 클러스터(ggg/khb/ljw/nmg/oje) + mgmt 자체 로그를 중앙 수집·시각화한다.
수집 경로: **각 클러스터 Filebeat DaemonSet → (tailnet) Logstash:5044 → Elasticsearch → Kibana**.
(Filebeat 매니페스트는 `acer-argocd` 저장소 `logging/` 에서 GitOps 로 배포한다.)

## 인덱스 라우팅 (Logstash `config/pipeline/90-outputs.conf`)

| log_type | 인덱스 |
|----------|--------|
| `k8s`    | `k8s-logs-<user>-YYYY.MM.dd` |
| `infra`  | `infra-logs-<user>-YYYY.MM.dd` |
| `audit`  | `acer-audit-<team>-YYYY.MM.dd` |
| 고신호 감사 복제본 | `acer-audit-alerts-<team>-YYYY.MM.dd` |
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
5. **보안 감사 data view + 대시보드** — default Space에 고정 ID `acer-audit` /
   `security-audit-overview`를 생성 또는 전체 교체하고 GET으로 재검증한다.

## Security Audit Overview

Kibana default Space에서 `Security Audit Overview`를 연다. 기본 범위는 최근 24시간,
자동 새로고침은 60초다.

관제 순서는 다음과 같다.

1. 상단 고정 컨트롤에서 감사 소스, 팀, 탐지 시그니처, 사용자, 호스트를 좁힌다.
2. `Current situation`의 전체 이벤트, 고신호 이벤트, Wazuh 알림, 활성 소스 수를 본다.
3. `Trend and collection coverage`에서 소스별 추세와 마지막 수집 시각을 확인한다.
4. `Immediate investigation`에서 최신 고신호 이벤트를 우선 조사한다.
5. 행위/사용자/호스트 피벗 후 전체 감사 타임라인에서 원문 맥락을 확인한다.

분석용 data view는 `acer-audit-*,-acer-audit-alerts-*`다. 고신호 이벤트는 원본 감사
인덱스와 알림 라우팅 인덱스에 함께 기록되므로, 복제본을 제외하지 않으면 KPI가 이중
집계된다. 고신호 여부는 원본 문서의 `labels.audit_alert`로 판단한다.

대시보드는 저장 객체 내부 구조를 직접 수정하지 않고 Kibana 9.4 Dashboards API로
선언적으로 적용한다. 이 API는 9.4에서 Technical Preview이므로 현재 스택은 9.4.3에
고정하며, 버전 변경 시 `security-audit.dashboard.json`을 대상 API로 다시 검증해야 한다.

## ⚠️ 보안 주의 — Space 는 접근제어가 아니다

이 스택은 `compose.yaml`에서 `xpack.security.enabled: true`이며 Elasticsearch/Kibana
서비스 계정 인증을 사용한다. 하지만 현재 팀별 Space는 여전히 **조직적 화면 분리**이고,
사람별 Kibana role/space 권한 매핑을 대신하지 않는다. 앞단 SSO를 통과한 사용자의 팀별
열람 범위를 강제하려면 native 사용자/역할 또는 별도의 라이선스·realm 설계가 필요하다.

## 미적용/후속 과제

- `service-logs-mgmt-v2-*` (mgmt 자체 도커 로그)는 하루 수 GB 규모인데 **보존정책 미부착**이다.
  필요 시 동일 ILM 을 붙이거나 노이즈 소스를 에이전트단에서 드롭할 것.
- 대량 유입 시 `Filebeat → Kafka → Logstash → ES` 버퍼링(이미 운영 중인 Kafka 활용) 고려.
