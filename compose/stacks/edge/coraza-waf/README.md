# coraza-waf — Standalone Coraza(OWASP CRS) origin WAF

**목적**: mgmt argocd 앞단에 OWASP CRS WAF 를 파일럿 배치한다. CRS 팀이 유지하는 turnkey
이미지(Caddy + coraza-caddy + OWASP CRS 번들)를 리버스 프록시 컨테이너로 두어, 애플리케이션
계층 공격(SQLi/XSS 등)을 탐지한다. 이전 traefik WASM 플러그인 방식은 prod traefik 을
크래시시켜 폐기했고, 그 대안이 이 별도 컨테이너 방식이다.

**이미지**: `ghcr.io/coreruleset/coraza-crs:4.25.0-caddy-alpine-202604120304` (핀, rolling 태그 금지)

**env**:
- `BACKEND=k3d-mgmt-serverlb:80` — WAF 통과 트래픽을 넘길 업스트림(k3d 인그레스 LB)
- `PORT=8080` — WAF 리슨 포트
- `CORAZA_RULE_ENGINE=DetectionOnly` — 탐지만(차단 안 함). `On`=차단(403), `Off`=비활성

**배선**: `traefik → coraza-waf:8080 → k3d-mgmt-serverlb:80`. traefik 의 파일 provider
동적 설정(`../traefik/config/dynamic/k3d.yaml`)에서 `k3d-argocd` 라우터가 `coraza-waf`
서비스(`http://coraza-waf:8080`)를 가리킨다. 세 컨테이너 모두 `mgmt-proxy` 네트워크에 있어
컨테이너명으로 서로 도달한다(이 호스트에선 k3d-mgmt-serverlb 도 mgmt-proxy 에 있음).

**DetectionOnly → On 전환법**: `compose.yaml` 의 `CORAZA_RULE_ENGINE` 을 `On` 으로 바꾸고
`docker compose -f compose.yaml up -d --force-recreate coraza-waf` 로 재적용한다. 전환 전
DetectionOnly 로그에서 오탐(false positive) 을 충분히 검토해 정상 트래픽 차단이 없는지
확인할 것. 문제가 없으면 On, 필요 시 다시 DetectionOnly/Off 로 즉시 되돌릴 수 있다.
