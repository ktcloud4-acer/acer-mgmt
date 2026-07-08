# acer-mgmt

ACER의 중앙 운영 서버를 선언적으로 관리한다. Docker Compose 서비스와 중앙
Argo CD용 k3d 클러스터는 실행 방식과 수명주기가 다르므로 최상위 디렉터리부터
분리한다.

## 구성

```text
acer-mgmt/
├── compose/     GitLab, Harbor, Traefik, 관측·데이터·백업 서비스
├── k3d/         중앙 Argo CD를 실행하는 단일 노드 관리 클러스터
└── secrets/     kubeconfig 등 수동 break-glass 자료(커밋 금지)
```

기존 자동화와 실행 중인 Docker bind mount의 경로 호환성을 위해 `stacks`,
`scripts`, `systemd`는 각각 `compose/` 아래를 가리키는 심볼릭 링크로 유지한다.

| 실행 계층 | 역할 | 상세 문서 |
|---|---|---|
| Docker Compose | GitLab, Harbor, Traefik, Vault, Prometheus 등 | [`compose/README.md`](compose/README.md) |
| k3d | k3s v1.35 관리 클러스터와 Argo CD | [`k3d/README.md`](k3d/README.md) |
| 원격 Kubernetes | 팀원별 애플리케이션 워크로드 | 별도 `acer-aio` 클러스터 |

Docker Traefik과 k3d는 `mgmt-proxy` 네트워크만 공유한다. HTTPS는 기존
Docker Traefik이 종료하고 `argocd.imcherry5778.xyz`를 k3d 내부 Ingress로 전달한다.

루트 `.env`는 `BASE_DOMAIN`, `DATA_ROOT`, `PROXY_NET`, `TZ` 같은 비시크릿
공통 설정만 담는다. 비밀번호, 토큰, 웹훅, 암호화 키는 Vault에서 관리하고
Vault Agent가 `/run/acer-mgmt/secrets/<domain>/<service>.env`로 렌더링한
파일을 Compose 실행 시 주입한다.

## 빠른 시작

### Docker Compose

```bash
./compose/scripts/bootstrap.sh
cd compose
docker compose --env-file ../.env \
  --env-file /run/acer-mgmt/secrets/edge/traefik.env \
  -f stacks/edge/traefik/compose.yaml up -d
docker compose --env-file ../.env \
  --env-file /run/acer-mgmt/secrets/cicd/gitlab.env \
  -f stacks/cicd/gitlab/compose.yaml up -d
docker compose --env-file ../.env \
  -f stacks/cicd/gitlab/compose.yaml ps
```

서비스별 Vault 렌더 env 파일이 없으면 해당 `--env-file` 인자는 생략한다.

### k3d와 Argo CD

```bash
cd k3d
./scripts/install-tools.sh
./scripts/validate.sh
mkdir -p /home/mgmt-data/k3d/mgmt ../secrets/k3d
docker network inspect mgmt-proxy >/dev/null 2>&1 || docker network create mgmt-proxy
k3d cluster create --config config.yaml
k3d kubeconfig get mgmt > ../secrets/k3d/mgmt.kubeconfig
chmod 600 ../secrets/k3d/mgmt.kubeconfig
KUBECONFIG=../secrets/k3d/mgmt.kubeconfig kubectl wait --for=condition=Ready node --all --timeout=180s
KUBECONFIG=../secrets/k3d/mgmt.kubeconfig ./scripts/bootstrap-argocd.sh
KUBECONFIG=../secrets/k3d/mgmt.kubeconfig ./scripts/smoke-test.sh
KUBECONFIG=../secrets/k3d/mgmt.kubeconfig kubectl get nodes -o wide
```

상세 운영 절차는 [acer-docs의 k3d-argocd-2026-06-30.md](https://gitlab.imcherry5778.xyz/acer-group/acer-docs/-/blob/main/acer-mgmt/docs/runbooks/k3d-argocd-2026-06-30.md)를
참조한다.

## 상세 문서

긴 아키텍처 문서, 운영 런북, 관측 설계 문서는 `acer-docs`에서 관리한다.

| 문서 | 내용 |
|---|---|
| [architecture-2026-06-29.md](https://gitlab.imcherry5778.xyz/acer-group/acer-docs/-/blob/main/acer-mgmt/docs/architecture-2026-06-29.md) | 중앙 운영 서버 아키텍처 |
| [services-2026-06-29.md](https://gitlab.imcherry5778.xyz/acer-group/acer-docs/-/blob/main/acer-mgmt/docs/services-2026-06-29.md) | 서비스 목록과 포트 |
| [runbook-2026-06-29.md](https://gitlab.imcherry5778.xyz/acer-group/acer-docs/-/blob/main/acer-mgmt/docs/runbook-2026-06-29.md) | 운영 런북 |
| [logging-design-2026-07-04.md](https://gitlab.imcherry5778.xyz/acer-group/acer-docs/-/blob/main/acer-mgmt/docs/logging-design-2026-07-04.md) | 로깅 설계 |
| [otel-tempo-tracing-setup-2026-07-05.md](https://gitlab.imcherry5778.xyz/acer-group/acer-docs/-/blob/main/acer-mgmt/docs/otel-tempo-tracing-setup-2026-07-05.md) | OTEL/Tempo 추적 설정 |

## 재부팅 복구

Compose의 Tailscale/Harbor 기동 순서 경쟁은 기존 oneshot으로 복구한다.

```bash
sudo install -m 0755 compose/scripts/boot-reconcile.sh \
  /usr/local/sbin/acer-mgmt-boot-reconcile
sudo restorecon -v /usr/local/sbin/acer-mgmt-boot-reconcile
sudo cp compose/systemd/acer-mgmt-reconcile.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now acer-mgmt-reconcile.service
```

k3d가 자동 복구되지 않으면 `cd k3d && k3d cluster start mgmt`를 실행한 뒤
`k3d kubeconfig get mgmt > ../secrets/k3d/mgmt.kubeconfig`로 kubeconfig를 갱신한다.

## 운영 제약

- 호스트: Rocky Linux 9.8, 20 CPU, RAM 62GiB, root 899GB
- Docker 서비스는 `/home/mgmt-data/<service>`에 데이터를 저장한다.
- k3d 상태는 `/home/mgmt-data/k3d/mgmt`에 저장한다.
- SELinux Enforcing이므로 데이터 루트는 `container_file_t`를 유지한다.
- `.env`에는 비시크릿 호스트 설정만 둔다. 시크릿 값, kubeconfig, Argo CD
  cluster credential은 커밋하지 않는다.
- 팀원 Kubernetes v1.36은 Argo CD 3.4 공식 테스트 범위 밖이므로 등록 후
  sync/health/prune을 실제 검증한다.
