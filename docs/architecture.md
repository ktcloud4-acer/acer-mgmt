# acer-mgmt 아키텍처

## 1. 전체 4계층

```
[4] Cloudflare (DNS/CDN/WAF + Tunnel)
          │  cloudflared (공인 IP 없이 인입)
          ▼
[3] mgmt 베어메탈 (이 저장소, docker compose)        ← Rocky 9.8 / 20c / 62GB
     edge(traefik·cloudflared·homepage)
     observability(prometheus·grafana·elk)
     security(vault)  cicd(gitlab·runner·sonarqube·harbor·semaphore)
     data(kafka·supabase)  backup(minio·restic)
          ▲ 메트릭/로그 수집           ▲ 이미지 pull / GitOps
[2] Kubernetes (master+worker1/2)  ──  App(Apache·Spring) · Argo CD · CSI/CCM · 익스포터
          ▲ VM/네트워크/스토리지
[1] OpenStack AIO (Keystone·Nova·Neutron·Cinder·Glance·Octavia·...)
```

1·2·4 계층은 **연동 대상**이며 mgmt에서 직접 기동하지 않는다. mgmt는 이들을 관측·배포·백업한다.

## 2. 오케스트레이션 모델

- 각 서비스 = **독립 compose 프로젝트** (`stacks/<도메인>/<서비스>/compose.yaml`).
- 공용 **외부 네트워크 `mgmt-proxy`** 로 Traefik ↔ 서비스 연결. DB 등 private 백엔드는 각 compose의 internal 네트워크에 격리.
- 진입: `Cloudflare Tunnel → Traefik(내부 단일 인그레스) → 서비스`.
- 운영 진입점은 `Makefile` (`make up s=<도메인>/<서비스>`).
- 대안(루트 umbrella + `include`/`profiles` 단일 프로젝트)은 이 규모에서 선택 기동 유연성이 떨어져 채택하지 않음.

## 3. 호스트 제약 (실측 2026-06-29, 192.168.50.162)

| 항목 | 값 | 대응 |
|------|-----|------|
| OS | Rocky Linux 9.8 / kernel 5.14 | Docker CE(centos repo) 사용 |
| CPU / RAM | 20 core / 62 GiB (+swap 31G) | 도메인 단위 선택 기동 |
| **디스크** | **root LV 899G (rl-home 병합 완료), swap 31G** | 데이터 경로 제약 해소 |
| SELinux | **Enforcing** | bind mount `:Z`, data-root relabel |
| 기존 런타임 | Podman 5.8 (idle) | 공존 OK, `podman.socket` mask |
| 방화벽 | firewalld + nftables | Docker DOCKER 체인 자동, 동시 가동 주의 |

### 디스크 배치 결정 (2026-06-29 갱신)
기본 설치 시 Anaconda 자동 파티셔닝이 root를 70GiB로 상한 처리하고 나머지(828G)를 별도 `rl-home` LV(/home)로 분리했다. mgmt 워크로드(GitLab/Harbor/ELK/MinIO)에는 root 70G가 부족하고 VG 여유가 0이라, **`rl-home` LV를 제거하고 그 공간을 root LV로 병합(`lvextend +100%FREE` + `xfs_growfs`) → root 899G로 확장**했다. 결과:
- Docker `data-root` 는 **기본값 `/var/lib/docker` 사용 가능**(override 불필요).
- 컨테이너 영속 데이터(`DATA_ROOT`)·MinIO 백업도 root FS 상 어디든 배치 가능.
- `/home` 은 더 이상 별도 LV가 아니라 root FS 상의 일반 디렉토리(user1 홈 보존됨).
- 원복 대비: 변경 전 fstab은 호스트의 `/etc/fstab.pre-resize.bak` 에 보관.

## 4. Docker vs Podman 공존

설치해도 안전. 근거: `podman-docker` shim 미설치 · `/usr/bin/docker` 부재(이름 충돌 X) · Podman inactive(소켓 충돌 X) · 런타임 스택 분리(containerd+runc vs crun+netavark).
watch-item: ① nftables — 둘을 동시 가동하면 규칙 간섭 가능 → podman idle + `systemctl mask podman.socket`. ② SELinux — bind mount 라벨.

## 5. 네트워크 / 시크릿 / 볼륨 규칙

- **네트워크**: 웹 노출 서비스는 `mgmt-proxy`(external) 연결 + Traefik 라벨. 백엔드는 compose-local 네트워크.
- **시크릿**: 부트스트랩 단계는 `.env`(gitignore), 런타임 중앙관리는 Vault. `secrets/` 디렉토리는 커밋 금지.
- **볼륨**: `config/`(커밋) ↔ `data`/`.env`/`secrets`(gitignore). 영속 데이터는 `DATA_ROOT` 하위.

## 6. 관측 연동 지점 (2계층 K8s)

`node-exporter`·`kube-state-metrics`·`OpenCost` 는 K8s 측 배포 → mgmt Prometheus의 **스크레이프 타깃**으로 등재(`observability/prometheus/config/prometheus.yml`). 로그는 Beats/log DaemonSet → mgmt ELK. Velero는 K8s 배포이고 백업 타깃 버킷만 mgmt MinIO에 생성.
