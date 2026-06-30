# k3d / Argo CD 운영 런북

## 정상 기동

```bash
make cluster-create
make argocd-bootstrap
make cluster-status
```

정상 조건:

- `k3d cluster list`에서 `mgmt` 서버와 load balancer가 실행 중
- `kubectl get node`에서 단일 노드가 `Ready`
- `argocd` namespace의 모든 Pod가 `Running`
- `https://argocd.imcherry5778.xyz`가 Argo CD 로그인 화면 반환

## 재부팅 후

k3d 노드 컨테이너는 Docker 재기동 정책으로 복구된다. 복구되지 않았으면 다음을
실행한다.

```bash
make cluster-start
make argocd-status
```

## 내부 경로 진단

```bash
# 호스트 → k3d serverlb → 내부 Traefik → Argo CD
curl -sSI -H 'Host: argocd.imcherry5778.xyz' http://127.0.0.1:8081/

# Docker Traefik → k3d serverlb
docker exec traefik \
  wget -S -O /dev/null --header='Host: argocd.imcherry5778.xyz' \
  http://k3d-mgmt-serverlb:80/
```

## Argo CD 동기화 검증

`make argocd-smoke`는 공개 guestbook 저장소를 임시 namespace에 동기화하고
`Synced/Healthy` 및 Deployment rollout을 확인한 다음 테스트 리소스를 정리한다.

## 장애 확인

```bash
docker logs k3d-mgmt-server-0 --tail 200
docker logs k3d-mgmt-serverlb --tail 200
KUBECONFIG=secrets/k3d/mgmt.kubeconfig \
  kubectl logs -n argocd statefulset/argocd-application-controller --tail=200
```

## 주의

- `k3d cluster delete mgmt`는 중앙 Argo CD 상태를 제거하는 파괴적 작업이다.
- 팀원 클러스터 credential은 Git에 커밋하지 않는다.
- 현재 팀원 Kubernetes v1.36은 Argo CD 3.4 공식 테스트 범위 밖이므로 연결 후
  실제 sync/health/prune 검증을 수행한다.
