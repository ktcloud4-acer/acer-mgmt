# Docker Compose 운영 계층

`compose/`는 mgmt 호스트에서 상시 실행하는 Docker Compose 서비스만 관리한다.
각 서비스는 독립 Compose 프로젝트이며, 외부 네트워크 `mgmt-proxy`를 통해
Docker Traefik과 연결된다.

## 구조

```text
compose/
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
    ├── infra/
    └── backup/
```

## 사용

`compose/` 안에서 서비스별 Compose 파일을 직접 지정한다.

```bash
cd compose
docker network inspect mgmt-proxy >/dev/null 2>&1 || docker network create mgmt-proxy
docker network inspect mgmt-data >/dev/null 2>&1 || docker network create mgmt-data

docker compose --env-file ../.env \
  --env-file /run/acer-mgmt/secrets/edge/traefik.env \
  -f stacks/edge/traefik/compose.yaml up -d

docker compose --env-file ../.env \
  -f stacks/edge/traefik/compose.yaml logs -f --tail=200
```

공통 환경변수는 저장소 루트의 `.env`에서 읽는다. 이 파일은 비시크릿
호스트 설정 전용이다. 시크릿은 Vault Agent가 렌더링한 런타임 파일로
주입한다.

Compose env 파일 주입 순서는 다음과 같다. 뒤쪽 파일이 앞쪽 값을 override 한다.

```text
../.env                                      # 비시크릿 공통 설정
stacks/<domain>/<service>/.env              # 기존 호환용 로컬 override
/run/acer-mgmt/secrets/<domain>/<service>.env # Vault Agent 렌더 시크릿
```

운영 호스트에서 `/run/acer-mgmt/secrets`가 없으면 부트 수렴 스크립트는 기존
Vault Agent 데이터 경로인 `/home/mgmt-data/vault-agent/secrets`를 fallback으로
사용한다.

새 시크릿은 `stacks/.../.env`나 루트 `.env`에 추가하지 않는다. Vault KV와
Vault Agent template을 통해 `/run/acer-mgmt/secrets/...` 아래로 렌더링한다.
필요한 키 이름은 [`vault-secrets.env.example`](vault-secrets.env.example)을
참고한다.

특정 env 파일이 없으면 해당 `--env-file` 인자는 생략한다.

## k3d 연동

Docker Traefik은 `stacks/edge/traefik/config/dynamic/k3d.yaml`을 통해
`argocd.imcherry5778.xyz` 요청을 k3d의 `k3d-mgmt-serverlb:80`으로 전달한다.
두 런타임은 `mgmt-proxy` Docker 네트워크만 공유한다.

Compose 서비스 정의와 Kubernetes 매니페스트를 섞지 않는다. k3d와 Argo CD는
[`../k3d/`](../k3d/)에서 관리한다.

저장소 루트의 `stacks`, `scripts`, `systemd` 심볼릭 링크는 기존 운영 경로와
실행 중인 컨테이너의 bind mount 호환성을 위한 별칭이다. 새 설정은 반드시
`compose/` 아래에서 수정한다.
