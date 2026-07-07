# acer-mgmt

ACER의 중앙 운영 서버를 선언적으로 관리한다. Docker Compose 서비스와 중앙
Argo CD용 k3d 클러스터는 실행 방식과 수명주기가 다르므로 최상위 디렉터리부터
분리한다.

## 구성

```text
acer-mgmt/
├── compose/     GitLab, Harbor, Traefik, 관측·데이터·백업 서비스
├── k3d/         중앙 Argo CD를 실행하는 단일 노드 관리 클러스터
├── secrets/     kubeconfig와 런타임 인증정보(커밋 금지)
└── Makefile     두 런타임의 공통 진입점
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

## 빠른 시작

### Docker Compose

```bash
./compose/scripts/bootstrap.sh
make compose-up s=edge/traefik
make compose-up s=cicd/gitlab
make compose-ps s=cicd/gitlab
```

기존 `make up|down|logs|ps s=...` 명령도 계속 지원한다.

### k3d와 Argo CD

```bash
make cluster-tools
make cluster-create
make argocd-bootstrap
make argocd-smoke
make cluster-status
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

k3d가 자동 복구되지 않으면 `make cluster-start`를 실행한다.

## 운영 제약

- 호스트: Rocky Linux 9.8, 20 CPU, RAM 62GiB, root 899GB
- Docker 서비스는 `/home/mgmt-data/<service>`에 데이터를 저장한다.
- k3d 상태는 `/home/mgmt-data/k3d/mgmt`에 저장한다.
- SELinux Enforcing이므로 데이터 루트는 `container_file_t`를 유지한다.
- `.env`, kubeconfig, Argo CD cluster credential은 커밋하지 않는다.
- 팀원 Kubernetes v1.36은 Argo CD 3.4 공식 테스트 범위 밖이므로 등록 후
  sync/health/prune을 실제 검증한다.
