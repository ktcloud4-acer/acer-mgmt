# k3d 관리 클러스터

`k3d/`는 mgmt 호스트에 중앙 Argo CD를 제공하는 단일 노드 Kubernetes
클러스터를 관리한다. 애플리케이션 워크로드는 이 클러스터가 아니라 팀원별 원격
클러스터에 배포한다.

## 구조

```text
k3d/
├── config.yaml                 k3d 클러스터 선언
├── versions.env               도구와 플랫폼 버전 고정
├── Makefile                   생성·부트스트랩·검증 명령
├── bootstrap/
│   ├── argocd/                Argo CD 설치와 Ingress
│   └── root/                  GitOps root Application 예시
├── tests/
│   └── smoke-application.yaml 실제 Argo CD 동기화 검증
└── scripts/
```

## 고정 버전과 포트

| 항목 | 값 |
|---|---|
| k3d | v5.9.0 |
| k3s | v1.35.6+k3s1 |
| kubectl | v1.35.6 |
| Argo CD | v3.4.4 |
| Kubernetes API | `127.0.0.1:6550` |
| 내부 Ingress 점검 | `127.0.0.1:8081` |
| Argo CD URL | `https://argocd.imcherry5778.xyz` |

k3d 노드는 기존 `mgmt-proxy` Docker 네트워크에 참가한다. 외부 HTTPS는 기존
Docker Traefik이 종료하고 k3d 내부 Traefik에는 HTTP로 전달한다.

## 설치

`k3d/` 디렉터리에서 실행한다.

```bash
cd k3d
make tools
make create
make bootstrap
make smoke
```

`tools`는 사용자 경로 `~/.local/bin`에 검증된 k3d, kubectl, argocd
바이너리를 설치한다. `create`는 멱등하게 기존 클러스터를 시작하거나 새로
생성하고 kubeconfig를 `secrets/k3d/mgmt.kubeconfig`에 기록한다.

## 상태 확인

```bash
cd k3d
make status
make argocd-status

KUBECONFIG=../secrets/k3d/mgmt.kubeconfig kubectl get pods -n argocd
curl -H 'Host: argocd.imcherry5778.xyz' http://127.0.0.1:8081/
```

초기 관리자 암호:

```bash
KUBECONFIG=../secrets/k3d/mgmt.kubeconfig \
  argocd admin initial-password -n argocd
```

## 팀원 클러스터 등록 전 확인

현재 `acer-argocd`의 Application은 `https://kubernetes.default.svc`를 대상으로
하므로 중앙 Argo CD에서 그대로 적용하면 mgmt 클러스터를 가리킨다. 팀원 API 경로와
RBAC을 준비한 뒤 다음을 수행한다.

1. mgmt의 Argo CD Pod에서 팀원 API `:6443` 접근 검증
2. 팀원별 제한된 ServiceAccount/RBAC 생성
3. 대상 클러스터를 Argo CD에 등록
4. Application의 `destination.server`를 등록된 API 주소로 변경
5. `bootstrap/root/application.example.yaml`을 검토 후 적용

클러스터 토큰과 kubeconfig는 커밋하지 않는다.

## 데이터와 삭제

k3s 상태는 `/home/mgmt-data/k3d/mgmt`에 저장한다. 클러스터 삭제는 명시적으로
확인해야 한다.

```bash
cd k3d
make destroy CONFIRM=mgmt
```

삭제 전에 Argo CD 설정과 클러스터 credential Secret을 별도로 백업해야 한다.
