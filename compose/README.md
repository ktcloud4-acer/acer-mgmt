# Docker Compose 운영 계층

`compose/`는 mgmt 호스트에서 상시 실행하는 Docker Compose 서비스만 관리한다.
각 서비스는 독립 Compose 프로젝트이며, 외부 네트워크 `mgmt-proxy`를 통해
Docker Traefik과 연결된다.

## 구조

```text
compose/
├── Makefile
├── scripts/
│   ├── bootstrap.sh
│   └── boot-reconcile.sh
├── systemd/
│   └── acer-mgmt-reconcile.service
└── stacks/
    ├── edge/
    ├── observability/
    ├── security/
    ├── cicd/
    ├── data/
    └── backup/
```

## 사용

저장소 루트에서는 접두사가 있는 명령을 사용한다.

```bash
make compose-up   s=edge/traefik
make compose-ps   s=cicd/gitlab
make compose-logs s=observability/elk
make compose-down s=data/kafka
```

기존 명령도 호환된다.

```bash
make up   s=edge/traefik
make logs s=edge/traefik
```

`compose/` 안에서 직접 실행할 수도 있다.

```bash
cd compose
make up s=edge/traefik
```

공통 환경변수는 저장소 루트의 `.env`에서 읽고, 서비스 전용
`stacks/<domain>/<service>/.env`가 있으면 해당 파일을 우선한다.

## k3d 연동

Docker Traefik은 `stacks/edge/traefik/config/dynamic/k3d.yaml`을 통해
`argocd.imcherry5778.xyz` 요청을 k3d의 `k3d-mgmt-serverlb:80`으로 전달한다.
두 런타임은 `mgmt-proxy` Docker 네트워크만 공유한다.

Compose 서비스 정의와 Kubernetes 매니페스트를 섞지 않는다. k3d와 Argo CD는
[`../k3d/`](../k3d/)에서 관리한다.

저장소 루트의 `stacks`, `scripts`, `systemd` 심볼릭 링크는 기존 운영 경로와
실행 중인 컨테이너의 bind mount 호환성을 위한 별칭이다. 새 설정은 반드시
`compose/` 아래에서 수정한다.
