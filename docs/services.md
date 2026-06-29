# 서비스 맵

`BASE_DOMAIN` 기준 서브도메인으로 Traefik 라우팅한다. 웹 서비스는 Tailscale
경로의 Traefik HTTPS로만 접근하고, DB/브로커 포트는 호스트에 공개하지 않는다.

| 도메인 | 서비스 | 역할 | 제안 URL | 메모 |
|--------|--------|------|----------|------|
| edge | traefik | 리버스 프록시/인그레스 | `traefik.${BASE_DOMAIN}` | 대시보드 보호 필요 |
| edge | cloudflared | Cloudflare Tunnel | — | Tailscale 전용 구성에서는 미기동 |
| edge | homepage | 포털 대시보드 | `home.${BASE_DOMAIN}` | 서비스 링크/상태 |
| observability | prometheus | 메트릭 수집 | `prometheus.${BASE_DOMAIN}` | K8s 익스포터 스크레이프 |
| observability | grafana | 시각화 | `grafana.${BASE_DOMAIN}` | datasource=prometheus,elk |
| observability | elk | 로그 수집/조회 | `kibana.${BASE_DOMAIN}` | ES heap·max_map_count |
| security | vault | 시크릿 관리 | `vault.${BASE_DOMAIN}` | unseal 절차 runbook |
| cicd | gitlab | SCM+DevOps | `gitlab.${BASE_DOMAIN}` | RAM 4~8G |
| cicd | gitlab-runner | CI 실행기 | — | gitlab 등록 토큰 |
| cicd | sonarqube | 정적분석 | `sonar.${BASE_DOMAIN}` | +postgres, max_map_count |
| cicd | harbor | 이미지 레지스트리 | `harbor.${BASE_DOMAIN}` | 멀티 컨테이너 |
| cicd | semaphore | Ansible GUI | `semaphore.${BASE_DOMAIN}` | 인프라 자동화 |
| data | kafka | 이벤트 스트리밍 | `kafka.${BASE_DOMAIN}` | KRaft + Kafka UI |
| data | supabase | BaaS | `supabase.${BASE_DOMAIN}` | 멀티 컨테이너 |
| backup | minio | S3 오브젝트 스토리지 | `minio.${BASE_DOMAIN}` | Velero/백업 타깃 |
| backup | restic | 호스트 볼륨 백업 | — | → minio, cron |

> URL/크리덴셜 실제 값은 `secrets/` · 각 서비스 `.env` 에 두고 커밋하지 않는다.

## 기본 로그인

로그인 기능이 있는 서비스는 아래 기본 아이디와 공통 `ADMIN_PASSWORD`를 사용한다.

| 서비스 | 아이디 |
|--------|--------|
| Traefik, Grafana, SonarQube, Semaphore, Vault | `admin` |
| MinIO | `minioadmin` |
| GitLab | `root` |
| Harbor | `admin` |
| Supabase Studio | `supabase` |

Prometheus, Kibana, Kafka UI, Homepage는 별도 애플리케이션 로그인이 없으며 tailnet
내부에서만 접근한다. Cloudflared는 Tailscale 전용 구성이라 기동하지 않는다.
