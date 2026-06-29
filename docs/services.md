# 서비스 맵

`BASE_DOMAIN` 기준 서브도메인으로 Traefik 라우팅. 포트는 호스트 직접 노출이 아닌 내부 기준(필요 시 조정).

| 도메인 | 서비스 | 역할 | 제안 URL | 메모 |
|--------|--------|------|----------|------|
| edge | traefik | 리버스 프록시/인그레스 | `traefik.${BASE_DOMAIN}` | 대시보드 보호 필요 |
| edge | cloudflared | Cloudflare Tunnel | — | ingress → traefik |
| edge | homepage | 포털 대시보드 | `${BASE_DOMAIN}` | 서비스 링크/상태 |
| observability | prometheus | 메트릭 수집 | `prometheus.${BASE_DOMAIN}` | K8s 익스포터 스크레이프 |
| observability | grafana | 시각화 | `grafana.${BASE_DOMAIN}` | datasource=prometheus,elk |
| observability | elk | 로그 수집/조회 | `kibana.${BASE_DOMAIN}` | ES heap·max_map_count |
| security | vault | 시크릿 관리 | `vault.${BASE_DOMAIN}` | unseal 절차 runbook |
| cicd | gitlab | SCM+DevOps | `gitlab.${BASE_DOMAIN}` | RAM 4~8G |
| cicd | gitlab-runner | CI 실행기 | — | gitlab 등록 토큰 |
| cicd | sonarqube | 정적분석 | `sonar.${BASE_DOMAIN}` | +postgres, max_map_count |
| cicd | harbor | 이미지 레지스트리 | `harbor.${BASE_DOMAIN}` | 멀티 컨테이너 |
| cicd | semaphore | Ansible GUI | `semaphore.${BASE_DOMAIN}` | 인프라 자동화 |
| data | kafka | 이벤트 스트리밍 | — | KRaft, +kafka-ui(옵션) |
| data | supabase | BaaS | `supabase.${BASE_DOMAIN}` | 멀티 컨테이너 |
| backup | minio | S3 오브젝트 스토리지 | `minio.${BASE_DOMAIN}` | Velero/백업 타깃 |
| backup | restic | 호스트 볼륨 백업 | — | → minio, cron |

> URL/크리덴셜 실제 값은 `secrets/` · 각 서비스 `.env` 에 두고 커밋하지 않는다.
