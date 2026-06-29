# 운영 런북

## 초기 구축 (mgmt 호스트, 1회)

```bash
# 1) Docker CE 설치 (Rocky 9 / centos repo)
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 2) (참고) root LV는 이미 899G로 확장됨 → data-root override 불필요(기본 /var/lib/docker 사용).
#    필요 시에만 /etc/docker/daemon.json 으로 위치 지정.

# 3) 서비스 활성화 + 권한
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"      # 재로그인 필요

# 4) Podman 간섭 차단 (선택)
sudo systemctl mask podman.socket

# 5) 부트스트랩
./scripts/bootstrap.sh
```

## 일상 운영

```bash
make up   s=<도메인>/<서비스>     # 기동
make down s=<도메인>/<서비스>     # 중지
make logs s=<도메인>/<서비스>     # 로그
make ps   s=<도메인>/<서비스>     # 상태
make config s=<도메인>/<서비스>   # compose 검증
```

## 기동 순서 권장

1. `edge/traefik` (+ `edge/cloudflared`)
2. `backup/minio` (백업 타깃 먼저)
3. `observability/*`
4. 필요한 `cicd/*` · `data/*` (RAM 예산 확인 후)

## 백업 / 복구

- 영속 데이터: `restic` → `minio` 증분.
- K8s 리소스/PV: Velero(K8s 측) → mgmt `minio` 버킷.
- 상세 절차 TODO.
