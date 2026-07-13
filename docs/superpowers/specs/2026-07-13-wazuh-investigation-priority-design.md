# Wazuh Investigation Priority Design

## Goal

Wazuh level 11 이상의 이벤트를 `Immediate investigation`에 포함하고, 대시보드에서 Wazuh 원본 레벨과 제품 공통 관제 우선순위를 혼동 없이 표시한다.

## Decisions

- Wazuh 원본 탐지 강도는 기존 `app.rule.level` 숫자 필드를 그대로 사용한다.
- 제품 공통 관제 우선순위는 `labels.alert_severity` 키워드 필드로 분리한다.
- 새 이벤트에는 문자열 `event.severity`를 더 이상 기록하지 않는다. ECS의 `event.severity`는 숫자형이어야 하지만 기존 인덱스에는 문자열 매핑이 존재할 수 있으므로, 이번 변경에서는 필드 타입 변경이나 과거 문서 재색인을 하지 않는다.
- 기존 원본 감사 인덱스와 알림 복제 인덱스의 보존·라우팅 구조는 유지한다.

## Detection Policy

Wazuh 이벤트는 다음과 같이 단일 시그니처와 우선순위를 부여한다.

| Wazuh level | `labels.audit_alert` | `labels.alert_severity` |
|---|---|---|
| 0–10 | 없음 | 없음 |
| 11 | `wazuh-investigation-required` | `medium` |
| 12–13 | `wazuh-high-severity` | `high` |
| 14 이상 | `wazuh-critical` | `critical` |

Vault root 토큰 사용과 민감한 `sys/*` 작업은 기존 시그니처를 유지하고 `labels.alert_severity=critical`을 기록한다.

## Dashboard

### Immediate investigation

- `labels.audit_alert IS NOT NULL` 조건은 유지한다.
- `Priority`는 `labels.alert_severity`를 표시한다.
- `Wazuh Level`은 `app.rule.level`을 표시한다. Vault 행에서는 이 값이 비어 있을 수 있으며 이는 정상이다.
- 시각적 컬럼 순서는 `Time`, `Priority`, `Wazuh Level`, `Alert signature`, `Source`, `Team`, `Actor`, `Endpoint`, `Rule`, `Outcome`, `Rule ID`, `Resource`로 한다.

### Wazuh host security

- 의미가 불분명하고 대부분 비어 있던 `Severity` 컬럼을 제거한다.
- 모든 Wazuh 이벤트에 존재하는 `app.rule.level`을 `Wazuh Level`로 표시한다.
- 나머지 `Endpoint`, `Rule`, `Rule ID`, `Collector` 컬럼은 유지한다.

## Mapping and Compatibility

- `labels.alert_severity`를 `keyword`로 신규·기존 `acer-audit-*` 인덱스에 추가한다.
- `app.rule.level`은 이미 Wazuh 문서에 숫자로 저장되므로 별도 복사본을 만들지 않는다.
- 과거 `event.severity` 값은 삭제하지 않지만 새 쿼리와 새 이벤트 생성에서는 사용하지 않는다.
- 기존 `labels.audit_alert`가 없는 일반 Wazuh 이벤트는 Immediate investigation에 들어가지 않는다.

## Tests

- 파이프라인 계약 테스트가 level 11/12–13/14+ 경계와 각 시그니처·우선순위를 검증한다.
- Logstash fixture 테스트가 실제 필터 실행 결과로 경계값을 확인한다.
- 대시보드 검증기가 `labels.alert_severity`, `app.rule.level`, 컬럼 라벨을 확인하고 `event.severity` 사용을 거부한다.
- 배포 전 JSON, Bash, Logstash 설정을 검증한다.
- 배포 후 level 11 이벤트가 Immediate investigation 쿼리에 반환되고, Wazuh 표 쿼리가 숫자 레벨을 반환하는지 확인한다.

## Out of Scope

- 기존 `event.severity` 필드의 타입 마이그레이션 또는 과거 문서 재색인
- 이메일·메신저·전화 호출 정책 변경
- Wazuh 자체 규칙 레벨 수정
- 빈도 기반 또는 다중 이벤트 상관분석 규칙 추가
