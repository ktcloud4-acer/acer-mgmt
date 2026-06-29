# acer-mgmt

ACER 인프라의 **플랫폼/운영 계층(mgmt 베어메탈)** 을 docker compose 로 구성하는 저장소입니다.
관측·CI/CD·시크릿·데이터·백업·엣지(리버스 프록시/터널) 도구 모음을 한 호스트에서 운영합니다.

## 전체 아키텍처에서의 위치

| 계층 | 구성 | 이 저장소와의 관계 |
|------|------|--------------------|
| 1. OpenStack AIO (IaaS) | Keystone/Nova/Neutron/Cinder/Glance ... | 연동 대상 (mgmt에서 직접 기동 안 함) |
| 2. Kubernetes (master+worker) | App 워크로드, Argo CD, CSI/CCM, 익스포터 | 메트릭/로그를 mgmt 관측 스택으로 전송 |
| **3. mgmt 베어메탈 (이 저장소)** | **docker compose 운영 도구 모음** | **본체** |
| 4. Cloudflare | DNS/CDN/WAF + Tunnel | `edge/cloudflared` 로 내부 노출 |

자세한 내용은 [`docs/architecture.md`](docs/architecture.md) 참조.

## 디렉토리 구조

```
stacks/
├── edge/           진입점 — traefik · cloudflared · homepage
├── observability/  관측 — prometheus · grafana · elk
├── security/       시크릿 — vault
├── cicd/           개발 플랫폼 — gitlab · gitlab-runner · sonarqube · harbor · semaphore
├── data/           데이터/메시징 — kafka · supabase
└── backup/         백업/스토리지 — minio · restic
```

각 서비스는 **독립 compose 프로젝트**이며, 공용 외부 네트워크 `mgmt-proxy` 를 통해 Traefik 이 라우팅합니다.

## 빠른 시작 (mgmt 호스트에서)

```bash
# 0) Docker 설치 후 1회 부트스트랩 (네트워크/커널/데이터 경로/SELinux)
./scripts/bootstrap.sh

# 1) 엣지(진입점) 먼저 기동
make up s=edge/traefik

# 2) 필요한 서비스만 선택 기동 (RAM 예산 고려)
make up s=observability/prometheus
make up s=cicd/gitlab

make ps   s=cicd/gitlab     # 상태
make logs s=cicd/gitlab     # 로그
make down s=cicd/gitlab     # 중지
```

## ⚠️ 운영 제약 (호스트: Rocky Linux 9.8)

- **디스크**: root LV 70GB뿐(VG 여유 0). 컨테이너 데이터는 용량 828GB인 **`/home` 하위(`DATA_ROOT`)** 에 둡니다. Docker `data-root` 도 `/home/docker` 권장.
- **RAM 62GB**: GitLab·ELK·Harbor·SonarQube·Supabase·Kafka 를 *전부 동시* 기동하면 부족 → 도메인/서비스 단위 선택 기동.
- **SELinux Enforcing**: bind mount 는 `:Z`, data-root 는 relabel 필요.
- **Podman 5.8 공존**: idle 유지 + `podman.socket` mask 권장(nftables 간섭 회피).
