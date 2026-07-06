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

# 5) Compose 부트스트랩
./compose/scripts/bootstrap.sh
```

## Docker 29.x 호환 (필수)

Docker Engine 29.x 는 최소 API 버전을 1.40 으로 올렸는데, Traefik docker provider 는
API 1.24 로 접속하며 `DOCKER_API_VERSION` 환경변수도 무시한다. 데몬이 구버전 API 를
다시 허용하도록 drop-in 을 추가한다(없으면 Traefik 라우팅이 전혀 동작하지 않음):

```bash
sudo mkdir -p /etc/systemd/system/docker.service.d
echo -e '[Service]\nEnvironment=DOCKER_MIN_API_VERSION=1.24' | \
  sudo tee /etc/systemd/system/docker.service.d/min-api.conf
sudo systemctl daemon-reload && sudo systemctl restart docker
docker version --format 'Min: {{.Server.MinAPIVersion}}'   # → Min: 1.24 확인
```

## 일상 운영

```bash
make compose-up     s=<도메인>/<서비스>  # 기동
make compose-down   s=<도메인>/<서비스>  # 중지
make compose-logs   s=<도메인>/<서비스>  # 로그
make compose-ps     s=<도메인>/<서비스>  # 상태
make compose-config s=<도메인>/<서비스>  # Compose 검증
```

## 기동 순서 권장

1. `edge/traefik` (+ `edge/cloudflared`)
2. `backup/minio` (백업 타깃 먼저)
3. `observability/*`
4. 필요한 `cicd/*` · `data/*` (RAM 예산 확인 후)

## 백업 / 복구

- 영속 데이터: `restic` → `minio` 증분.
- K8s 리소스/PV: Velero(K8s 측) → mgmt `minio` 버킷.
- AdGuard Home: `adguard-backup.timer` 가 매일 03:20 KST 에
  `/home/mgmt-data/adguard` 를 `db-backup/adguard/daily/<stamp>/` 로 백업.
- 상세 복구 절차 TODO.

## DNS 운영 기준

내부 운영 도메인(`imcherry5778.xyz`)은 AdGuard Home 을 기준 resolver 로 둔다.
Kubernetes 내부 도메인(`*.svc.cluster.local`)은 각 클러스터 CoreDNS 가 처리하고,
Docker 컨테이너 이름은 Docker embedded DNS(`127.0.0.11`)가 처리한다. Tailscale
MagicDNS(`*.tailc0244b.ts.net`)는 Tailscale DNS(`100.100.100.100`)에 남긴다.

```bash
# AdGuard 자체 DNS 확인
./compose/scripts/dns-smoke-test.sh

# k3d 관리 클러스터 split DNS 적용/복구
make cluster-dns
```

Tailscale admin console 에서는 Split DNS route 를 추가한다.

| Domain | Nameserver |
|---|---|
| `imcherry5778.xyz` | `100.117.59.96` |

nmg 같은 원격 kubeadm 클러스터는 CoreDNS 에 별도 server block 을 둔다.

```text
imcherry5778.xyz:53 {
    errors
    cache 30
    forward . 100.117.59.96
}
```

기본 외부 도메인은 기존 upstream 을 유지한다. 이렇게 해야 내부 운영 도메인만
AdGuard 로 수렴하고, Kubernetes/Docker/Tailscale 고유 DNS 역할이 깨지지 않는다.

## k3d / Argo CD

중앙 Argo CD 관리 클러스터는 [`runbooks/k3d-argocd.md`](runbooks/k3d-argocd.md)를
참조한다.
