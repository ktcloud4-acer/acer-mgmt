# ACER 관리자 셸 및 단일 SSO 설계

## 결정

`platform-admin` 그룹만 관리 UI에 접근할 수 있게 한다. Keycloak은 유일한
Identity Provider(IdP)이고, Dashy는 모든 관리 UI를 iframe으로 표시하는
관리자 셸이다. 서비스별 인증 구현은 같을 필요가 없지만, 사용자는 Keycloak
세션을 재사용하므로 추가 비밀번호 입력 없이 각 UI에 들어간다.

이 설계는 브라우저 UI에만 적용한다. S3, Vault API, Kubernetes, 서비스 간
통신과 자동화에는 각각의 service token, JWT, mTLS 또는 application credential를
계속 사용한다.

## 현재 문제

현재 시스템은 네 가지 모델이 섞여 있다.

1. Traefik `sso-auth` -> oauth2-proxy -> Keycloak.
2. 앱의 Keycloak 네이티브 OIDC.
3. Teleport의 로컬 계정 + OTP.
4. 서비스 자체 계정 또는 API credential.

Semaphore는 1번만 적용되어 있다. oauth2-proxy는 사용자를 인증하지만
Semaphore는 그 헤더로 내부 세션을 만들지 않는다. `/api/user`가 401을 반환하고
Traefik의 error middleware가 이를 다시 oauth2-proxy 로그인으로 바꾸므로 무한
리다이렉트와 `Network Error`가 발생한다.

Keycloak에는 `semaphore` client가 있지만 Semaphore runtime에는
`SEMAPHORE_OIDC_PROVIDERS` 또는 `oidc_providers`가 없다. 이는 반쪽 구성이다.

## 목표 아키텍처

```text
Browser
  -> Dashy (platform-admin, oauth2-proxy -> Keycloak)
      -> iframe: 각 관리 UI
          -> native OIDC 서비스: Keycloak Authorization Code flow
          -> auth-proxy 서비스: oauth2-proxy forward auth
          -> API/agent: 서비스 전용 token/JWT/mTLS

Teleport
  -> Keycloak OIDC
  -> SSH, Kubernetes, session recording, emergency administration
```

Dashy는 trusted parent origin으로 고정한다. 모든 iframe 대상은
`https://dashy.imcherry5778.xyz`만 `frame-ancestors`로 허용한다. 와일드카드와
`*`는 사용하지 않는다.

## 인증 모델

### 1. Dashy와 auth-proxy 모델

Dashy는 `platform-admin` browser gate를 계속 사용한다. 다음처럼 앱 자체의
사용자 모델이 없거나 auth-proxy를 공식 지원하는 서비스도 같은 gate를 사용한다.

- Prometheus, Alertmanager, Allure, Playwright, Traefik dashboard
- Kibana, n8n, Kafka UI, SonarQube, AdGuard, Wazuh: native OIDC가 도입되기 전의
  browser gate

Grafana는 현행 header-auth를 유지하지 않는다. 이미 존재하는 Keycloak client를
이용해 native OIDC로 이전한다. 이렇게 하면 사용자·세션·권한의 source of truth가
Keycloak과 Grafana가 되고, Traefik header allowlist에 의존하지 않는다.

auth-proxy 보호 서비스에서 `401`과 `403`은 앱 자체 로그인 실패가 아니라
unauthenticated browser gate에만 사용한다. 앱 API의 401을 Keycloak 리다이렉트로
바꾸는 error middleware는 native OIDC 서비스에 붙이지 않는다.

### 2. native OIDC 모델

다음 서비스는 앱 안에 사용자, role 또는 고유 token이 있으므로 Keycloak native
OIDC를 사용한다. 기본적으로 이 라우터에는 `sso-auth`를 적용하지 않는다. 단,
Semaphore는 첫 UI 진입과 API/OIDC callback을 분리하는 예외 모델을 사용한다.

| 서비스 | 목표 방식 | 비고 |
|---|---|---|
| Semaphore | Keycloak OIDC + oauth2-proxy group gate | OIDC는 Semaphore 세션을 만들고, redirect 없는 `oauth2-auth`는 `platform-admin` admission을 보장한다. |
| Vault UI | Vault OIDC auth method | OIDC login으로 Vault token과 policy를 발급한다. `/v1/*` API bypass는 유지한다. |
| Grafana | Generic OAuth / Keycloak OIDC | 현행 auth-proxy header trust를 제거한다. |
| NetBox | Keycloak OIDC | 기존 group mapping은 유지하고 `platform-admin`만 접근하도록 한다. |
| GitLab | Keycloak OpenID Connect | 기존 OmniAuth를 유지한다. |
| Argo CD | Keycloak OIDC | 기존 client를 실제 dex/Argo OIDC 설정과 대조한다. |
| Harbor | Keycloak OIDC | Harbor 자체 role/group mapping을 구성한다. |
| MinIO Console | Keycloak OIDC | S3 API는 OIDC browser flow와 분리한다. |
| Teleport | Keycloak OIDC | OIDC connector를 실제 등록하고 local+OTP는 break-glass 전용으로 둔다. |

Semaphore Community는 OIDC group claim으로 로그인 자체를 제한하거나 project role을
자동 할당하지 않는다. 따라서 Semaphore는 두 router를 사용해 `platform-admin`을
먼저 검증한다. UI route(`/api` 이외)는 `sso-auth`를 사용해 첫 방문을 oauth2-proxy와
Keycloak 로그인으로 보낸다. API route(`/api/*`, OIDC callback 포함)는 redirect 없는
`oauth2-auth`만 사용한다. 이로써 Semaphore의 자체 API 401은 Keycloak 리다이렉트로
바뀌지 않으면서, direct UI URL과 Dashy iframe 모두 정상적으로 로그인 흐름을 시작한다.

Supabase Studio, Wazuh, Kibana, n8n, Kafka UI, SonarQube는 해당 버전/라이선스의
native OIDC 또는 remote-user 지원 여부를 검증한 뒤 native OIDC 또는 auth-proxy
모델 중 하나를 선택한다. 기능이 없으면 auth-proxy가 UI의 access boundary가 되고
서비스 로컬 계정은 break-glass 또는 서비스 전용으로 유지한다.

### 3. Teleport의 역할

Teleport는 없애지 않는다. SSH, Kubernetes, database/app access, session recording,
audit와 emergency administration을 담당한다. Teleport App Access에 중복 등록된
Kibana, Prometheus, Alertmanager, Vault, AdGuard, Traefik, MinIO, Semaphore는 Dashy의
주 경로로 사용하지 않는다. Dashy에는 Teleport 웹 콘솔 하나만 iframe으로 넣고,
중복 application subdomain은 migration 확인 후 제거한다.

## iframe 보안 계약

각 iframe 대상에 다음 계약을 적용한다.

1. 응답의 `X-Frame-Options`를 제거하거나 Dashy와 충돌하지 않게 한다.
2. `Content-Security-Policy`의 `frame-ancestors`는 정확히
   `https://dashy.imcherry5778.xyz`만 허용한다.
3. Dashy의 `frame-src`는 관리 서비스의 명시 allowlist만 사용한다.
4. iframe navigation과 OIDC callback은 child frame 안에서 완료할 수 있어야 한다.
   Keycloak callback/로그인 페이지도 Dashy ancestor를 허용한다.
5. Dashy 자체는 `platform-admin`에게만 제공하고, 임의 URL을 iframe으로 여는 기능은
   비활성화한다.

이 계약은 clickjacking 노출을 Dashy 하나로 제한한다. Dashy XSS는 모든 framed
admin UI에 영향을 줄 수 있으므로 Dashy config write, local save, 임의 URL embed는
계속 비활성화한다.

## 서비스 라우팅 정책

- **native OIDC UI**: Traefik `secure-headers` + per-service iframe header policy. Semaphore는
  `platform-admin` admission과 첫 방문 redirect를 위해 UI에 `sso-auth`, API/OIDC callback에
  redirect 없는 `oauth2-auth`를 각각 적용한다.
- **auth-proxy UI**: Traefik `sso-auth` + per-service iframe header policy. oauth2-proxy
  cookie domain은 `.imcherry5778.xyz`로 유지한다.
- **machine API**: browser `sso-auth` 없음. 서비스 API 인증으로 보호한다.
- **Teleport**: port 3080의 native Keycloak OIDC. Dashy iframe 대상은 Teleport console
  하나이며, app proxy는 일반 UI의 중복 경로가 아니다.

## 구현 순서

1. 현재 source/runtime/Keycloak client 차이를 inventory로 고정한다. SonarQube runtime
   header 설정과 Git source 차이, orphan Keycloak client, Teleport connector 미적용 상태를
   해소한다.
2. Keycloak client와 Vault secrets를 서비스별로 관리한다. client secret을 Compose env에
   직접 넣지 않는다.
3. Semaphore native OIDC를 먼저 완성한다. UI/API router를 분리하고 iframe 안에서 fresh
   private-browser login, `/api/user`, logout을 검증한다.
4. Vault UI, Grafana, Teleport, MinIO/Harbor, NetBox/GitLab/Argo CD 순서로 native OIDC를
   정리한다.
5. auth-proxy 전용 서비스는 API 401을 sign-in redirect로 바꾸지 않도록 router-level
   정책을 분리한다.
6. Dashy iframe allowlist와 모든 child CSP/XFO 정책을 적용한다.
7. 중복 Teleport App Access web route를 deprecate하고 SSH/Kubernetes/audit 기능은
   유지한다.

## 검증 계약

각 서비스에 대해 다음을 자동/수동으로 검증한다.

1. fresh private browser에서 Dashy 로그인은 `platform-admin`만 성공한다.
2. Dashy iframe이 child UI를 표시하고 CSP/XFO violation이 없다.
3. native OIDC 서비스의 API가 oauth2-proxy sign-in URL로 302되지 않는다.
4. Semaphore `/api/user`는 Keycloak 로그인 뒤 200이며 `Network Error`가 없다.
5. service API는 browser login redirect 없이 기존 token/JWT/mTLS 동작을 유지한다.
6. direct service URL과 Dashy iframe URL 모두 Keycloak session reuse로 비밀번호 재입력이
   없어야 한다.
7. Teleport Keycloak login, SSH, Kubernetes access와 audit session recording이 동작한다.

## 성공 기준

`platform-admin` 사용자는 Dashy 한 번의 로그인 뒤 모든 등록 UI를 iframe에서 열 수 있다.
각 서비스는 자신의 RBAC와 audit identity를 유지한다. Semaphore, Vault, Teleport에서
브라우저 redirect loop나 `Network Error`가 발생하지 않으며, API endpoint는 browser SSO
middleware 때문에 깨지지 않는다.
