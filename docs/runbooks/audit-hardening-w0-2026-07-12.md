# 감사 강화 W0 — cutover 런북 (2026-07-12)

보안 감사(audit)의 3대 약점을 **무료(Basic)** 범위 설정으로 메운다.

| 파트 | 무엇을 | 산출물 |
|---|---|---|
| P1 | ES security 활성 + 최소권한 RBAC (감사 무결성) | `compose.yaml`, `elk-security-bootstrap.sh`, `90-outputs.conf` |
| P2 | 감사 전용 ILM(90일) + replica0 템플릿 (보존·yellow 해소) | `config/ilm/acer-audit-*`, `apply-observability.sh` |
| P2b | MinIO 스냅샷 백업 (SLM 일일) | `config/snapshot/*`, `elk-snapshot-bootstrap.sh` |
| P3 | 고신호 감사 탐지 + 전용 알림 인덱스 | `pipeline/50-audit-alerts.conf`, 알림 라우팅 |
| P4 | 통합 감사 관제 화면 | `security-audit.dashboard.json`, `apply-observability.sh` |

> 적용 대상은 라이브 mgmt 호스트다. **아래 순서를 지키지 않으면 로그 파이프라인이 잠깐
> 끊긴다.** 특히 P1 은 kibana_system 패스워드를 부트스트랩한 뒤에 Kibana 를 올려야 한다.

## 사전 준비 — Vault 시크릿 렌더

아래 키를 Vault 에 넣고 Vault Agent 가 `/run/acer-mgmt/secrets/observability/elk.env`
로 렌더링하도록 한다(값은 git·명령행에 두지 않는다).

```
ELK_ELASTIC_PASSWORD          # elastic superuser
ELK_KIBANA_PASSWORD           # kibana_system
ELK_LOGSTASH_PASSWORD         # logstash_ingest
ELK_KIBANA_ENCRYPTION_KEY     # 32자 이상
ELK_KIBANA_SO_ENCRYPTION_KEY  # 32자 이상
# 스냅샷(P2b, 선택)
MINIO_ENDPOINT SNAPSHOT_BUCKET S3_ACCESS_KEY S3_SECRET_KEY
```

렌더된 env 는 아래 절차에서 `set -a; . <파일>; set +a` 로 export 한다.

## P1 cutover (순서 중요)

```bash
cd compose/stacks/observability/elk
set -a; . /run/acer-mgmt/secrets/observability/elk.env; set +a

# 1) Elasticsearch 만 먼저 보안 활성으로 재기동 (elastic 초기 패스워드 부트스트랩)
make up s=observability/elk            # 또는 docker compose up -d elasticsearch
#    → ES healthy 확인(내부적으로 elastic 인증 healthcheck)

# 2) 내장계정 패스워드 + 최소권한 role/user 부트스트랩
./scripts/elk-security-bootstrap.sh
#    kibana_system 패스워드, logstash_writer(삭제불가), logstash_ingest, acer_audit_viewer

# 3) Kibana / logstash-consumer 를 자격증명과 함께 (재)기동
docker compose up -d kibana logstash logstash-consumer

# 4) 보존정책/템플릿/기존 인덱스 보정 + 감사 대시보드(P2/P4)
ES_USER=elastic ES_PASSWORD="$ELK_ELASTIC_PASSWORD" ./scripts/apply-observability.sh
```

**검증**
```bash
# 익명 접근 차단(401 이어야 정상)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9200        # 401
# 인증 조회
curl -s -u "elastic:$ELK_ELASTIC_PASSWORD" http://127.0.0.1:9200/_cat/indices/acer-audit-*?v
# 최소권한 계정은 삭제 불가(403 이어야 정상)
curl -s -o /dev/null -w '%{http_code}\n' -u "logstash_ingest:$ELK_LOGSTASH_PASSWORD" \
  -X DELETE http://127.0.0.1:9200/acer-audit-mgmt-*                    # 403
# 로그 유입 지속 확인
curl -s -u "elastic:$ELK_ELASTIC_PASSWORD" 'http://127.0.0.1:9200/acer-audit-mgmt-*/_count'

# 감사 data view: 알림 라우팅 복제본을 제외해야 함
curl -sf -u "elastic:$ELK_ELASTIC_PASSWORD" \
  http://127.0.0.1:5601/api/data_views/data_view/acer-audit \
  | jq -e '.data_view.title == "acer-audit-*,-acer-audit-alerts-*"'

# 선언형 대시보드가 고정 ID/제목으로 저장됐는지 확인
curl -sf -u "elastic:$ELK_ELASTIC_PASSWORD" \
  http://127.0.0.1:5601/api/dashboards/security-audit-overview \
  | jq -e '.id == "security-audit-overview" and .data.title == "Security Audit Overview"'
```

Kibana default Space에서 `Security Audit Overview`를 열고 최근 24시간/60초 새로고침,
상단 5개 필터, 소스별 마지막 수집 시각, 고신호 이벤트 표를 확인한다. KPI는
`acer-audit-alerts-*` 복제본을 제외한 원본 감사 이벤트 기준이다.

**롤백**: `compose.yaml` 의 `xpack.security.enabled` 를 `false` 로 되돌리고
`90-outputs.conf` 의 `user/password` 라인을 제거 후 재기동. (보안 인덱스는 남지만
비활성 상태에선 무시된다.)

## P2 / P2b 검증

```bash
# ILM 부착(managed:true 이어야 함) + green
curl -s -u "elastic:$ELK_ELASTIC_PASSWORD" \
  'http://127.0.0.1:9200/acer-audit-*/_ilm/explain?only_managed=false' | jq '.indices[].managed'
curl -s -u "elastic:$ELK_ELASTIC_PASSWORD" 'http://127.0.0.1:9200/_cat/indices/acer-audit-*?h=health'

# 스냅샷(선택)
./scripts/elk-snapshot-bootstrap.sh
curl -s -u "elastic:$ELK_ELASTIC_PASSWORD" -X POST \
  'http://127.0.0.1:9200/_slm/policy/acer-audit-snapshot/_execute'
```

> 주의(P2b): MinIO 가 같은 호스트면 물리 단일장애까지 막지는 못한다(오삭제·인덱스 손상
> 복구용). 오프호스트 DR 은 MinIO 자체 복제/백업 정책이 필요.

## P3 — 탐지 및 Alertmanager 연동(옵션)

탐지 스탬프(`vault-root-token-used`, `vault-sensitive-sysop`, `wazuh-high-severity`)는
`acer-audit-alerts-<team>-*` 인덱스에 즉시 색인된다.

```bash
curl -s -u "elastic:$ELK_ELASTIC_PASSWORD" \
  'http://127.0.0.1:9200/acer-audit-alerts-*/_search?q=labels.audit_alert:*&size=5'
```

**Slack 알림(→ 기존 Alertmanager) 연동은 의도적으로 인라인에 넣지 않았다.** 이유:
Logstash 인라인 `http` output 이 Alertmanager 미도달 시 재시도로 **로그 파이프라인
전체에 백프레셔**를 줄 수 있다. 연동하려면 아래를 **별도 파이프라인**(consumer 와
분리된 전용 Logstash 인스턴스 또는 dead-letter 안전장치 포함)에서 테스트 후 활성화한다:

```conf
# Alertmanager /api/v2/alerts 는 JSON 배열을 요구 → format=json_batch
# 이벤트를 {labels:{...}, annotations:{...}} 형태로 ruby/mutate 재구성 후:
output {
  if [labels][audit_alert] {
    http {
      url => "${ALERTMANAGER_URL}/api/v2/alerts"
      http_method => "post"
      format => "json_batch"
      # retry/backoff 를 짧게, 실패 시 drop 되도록 별 파이프라인에서 운용할 것
    }
  }
}
```

대안: Wazuh 디코더로 Vault 감사 로그를 읽어 Wazuh 규칙→기존 Wazuh 알림 경로 재사용.

## 남은 트레이드오프(설계상 명시)

- 사람별 RBAC(감사 열람자 vs 관리자)는 Basic + oauth2-proxy 프론트에선 완전하지 않다.
  Kibana 는 kibana_system 서비스계정으로 동작하고, 사람 접근은 앞단 SSO 로 게이트한다.
  진짜 per-user 구분은 native 계정 또는 OIDC realm(Platinum)이 필요 — 별도 결정 사항.
- 감사 인덱스 팀별 문서레벨 격리(DLS)도 Platinum. 현재는 인덱스 분리(`-<team>-`)로 대체.
