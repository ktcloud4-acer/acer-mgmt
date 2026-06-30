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

## 재부팅 복구 (부팅 순서 경쟁 해소)

호스트 재부팅 시 docker 데몬이 `tailscaled`/`harbor-log` 보다 먼저 떠서, tailnet IP에
bind 하는 스택(`elk`·`gitlab`)과 syslog 로깅을 쓰는 `harbor` 스택은 컨테이너 복구가
1회 실패한 뒤 docker 가 재시도를 포기해 멈춰버린다. (restart 정책 문제가 아니라 기동
순서/타이밍 경쟁)

이를 위해 부팅 후 의존성이 준비되면 멈춘 스택만 멱등하게 재기동하는 oneshot 을 둔다.

```bash
# SELinux Enforcing: 실행 바이너리는 /home(user_home_t) 가 아니라 /usr/local/sbin(bin_t)에 둔다.
sudo install -m 0755 scripts/boot-reconcile.sh /usr/local/sbin/acer-mgmt-boot-reconcile
sudo restorecon -v /usr/local/sbin/acer-mgmt-boot-reconcile
sudo cp systemd/acer-mgmt-reconcile.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now acer-mgmt-reconcile.service   # 즉시 복구 + 다음 부팅부터 자동

journalctl -u acer-mgmt-reconcile -n 50   # 동작 확인
```

- 로직: [`scripts/boot-reconcile.sh`](scripts/boot-reconcile.sh) — tailscale IP 할당 대기 →
  `TAILSCALE_IP` bind 스택 `make up` → `harbor-log` 기동 확인 후 나머지 harbor 컨테이너 `start`.
- harbor 는 설치 생성 compose 가 스텁이라 `compose up` 불가 → 기존 컨테이너를 순서대로 start 한다.
- repo 경로는 unit 의 `ACER_MGMT_REPO` 환경변수로 주입한다(설치본은 스크립트 위치로 repo 추정 불가).
- ⚠️ `/home` 아래 스크립트를 systemd 가 직접 `ExecStart` 하면 SELinux 가 막는다(`203/EXEC`).

## ⚠️ 운영 제약 (호스트: Rocky Linux 9.8)

- **디스크**: root LV를 **899GB로 확장 완료**(기본 설치의 70G root에 `rl-home` LV 828G를 병합, 2026-06-29). `/home`은 이제 root FS 상의 일반 디렉토리. 컨테이너 데이터/`data-root`는 기본 경로(`/var/lib/docker`) 또는 `DATA_ROOT` 어디든 배치 가능.
- **RAM 62GB**: GitLab·ELK·Harbor·SonarQube·Supabase·Kafka 를 *전부 동시* 기동하면 부족 → 도메인/서비스 단위 선택 기동.
- **SELinux Enforcing**: bind mount 는 `:Z`, data-root 는 relabel 필요.
- **Podman 5.8 공존**: idle 유지 + `podman.socket` mask 권장(nftables 간섭 회피).
