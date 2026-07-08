# NetBox — IPAM / CMDB (infra)

인프라의 "기준 장부(source of truth)". IP 대역, VM/노드, 클러스터, VLAN/VRF,
DNS 이름, 서비스 소유자를 한 곳에서 관리한다. TLS 는 Traefik 이 종단하고
SSO 는 Keycloak realm `mgmt` 의 OIDC 로 통합한다.

## 구성

| 컨테이너 | 이미지 | 역할 |
|---|---|---|
| `netbox` | `netboxcommunity/netbox:v4.5-4.0.2` | 웹/API (Granian, 내부 8080) |
| `netbox-worker` | 〃 | 백그라운드 작업(rqworker) |
| `netbox-housekeeping` | 〃 | 주기적 정리 작업 |
| `netbox-db` | `postgres:18-alpine` | 데이터베이스 |
| `netbox-redis` | `valkey/valkey:9.0-alpine` | 작업 큐(영속) |
| `netbox-redis-cache` | `valkey/valkey:9.0-alpine` | 캐시(비영속) |

`netbox` 만 `mgmt-proxy` 에 붙어 Traefik 이 `netbox.${BASE_DOMAIN}` 으로 라우팅한다.
db/redis 는 프로젝트 기본 네트워크에만 있어 외부로 노출되지 않는다.

## 시크릿 (Vault)

값은 커밋하지 않는다. Vault KV 에 저장하고 Vault Agent 가
`/run/acer-mgmt/secrets/infra/netbox.env` 로 렌더링한다. 필요한 키는
[`../../../vault-secrets.env.example`](../../../vault-secrets.env.example) 참고.

```bash
# 값 생성 예시
docker run --rm netboxcommunity/netbox:v4.5-4.0.2 \
  /opt/netbox/venv/bin/python /opt/netbox/netbox/generate_secret_key.py  # NETBOX_SECRET_KEY
openssl rand -base64 36   # DB / REDIS 패스워드, OIDC_CLIENT_SECRET
openssl rand -hex 20      # NETBOX_SUPERUSER_API_TOKEN (40 hex)
```

## SSO (Keycloak OIDC)

1. Keycloak 과 NetBox 가 같은 `NETBOX_OIDC_CLIENT_SECRET` 값을 쓰도록 Vault 에 저장한다.
2. Keycloak 에 클라이언트 `netbox` 와 그룹/매퍼를 등록한다:

   ```bash
   ENV_FILE=/home/user1/acer-mgmt/.env \
   KEYCLOAK_ADMIN_PASSWORD=... \
   NETBOX_OIDC_CLIENT_SECRET=... \
     ./compose/scripts/keycloak-netbox-bootstrap.sh
   ```

   - 콜백 URL: `https://netbox.${BASE_DOMAIN}/oauth/complete/oidc/`
   - `groups` 클레임 매퍼를 등록하므로, 이후 `config/extra.py` 의 파이프라인
     스텝을 활성화하면 `platform-admin` 그룹 → superuser 자동 매핑이 가능하다.
3. 로컬 슈퍼유저 로그인은 SSO 와 병행 유지되어 브레이크글래스로 쓴다. 초기
   기동 뒤에는 compose 의 `SKIP_SUPERUSER=true` 로 바꿔 재기동을 권장한다.

env 로 노출되지 않는 설정(`CSRF_TRUSTED_ORIGINS`, social-auth OIDC)은
[`config/extra.py`](config/extra.py) 에서 `os.environ` 값으로 채운다.

## 배포

```bash
cd compose
docker network inspect mgmt-proxy >/dev/null 2>&1 || docker network create mgmt-proxy
docker compose --env-file ../.env \
  --env-file /run/acer-mgmt/secrets/infra/netbox.env \
  -f stacks/infra/netbox/compose.yaml up -d
docker compose --env-file ../.env \
  --env-file /run/acer-mgmt/secrets/infra/netbox.env \
  -f stacks/infra/netbox/compose.yaml ps
```

## 백업

`netbox-db` 를 논리 백업(pg_dump)하여 MinIO 로 올린다. `scripts/mgmt-db-backup.sh`
의 supabase 블록과 동일 패턴:

```bash
docker exec -u postgres netbox-db pg_dump -d netbox -Fc > netbox.dump
```

## 데이터 투입 (인프라 인벤토리 → NetBox 모델)

| 정보 | NetBox 객체 | 예시 |
|---|---|---|
| 위치/사이트 | Region / Site | KT Cloud, AIO, nmg |
| 소유자 | Tenant | imcherry, acer-group |
| 네트워크 격리 | VRF | kt-cloud, tailnet, k8s-internal |
| IP 대역/용도 | Prefix | 172.16.1.0/24, 172.16.8.0/24, 10.20.0.0/24, 100.64.0.0/10 |
| 노드/서버 | Device / VM | AIO(172.16.1.10), mgmt(100.117.59.96), nmg 노드(172.16.8.51~53) |
| 클러스터 | Virtualization > Cluster | nmg(kubeadm), mgmt(k3d) |
| DNS 이름 | IP Address.dns_name | netbox.imcherry5778.xyz 등 |
| 서비스/포트 | Service | gitlab:443, harbor:443, vault:8200 |

투입은 (1) CSV Import 로 초기 부트스트랩 → (2) `terraform-provider-netbox`
또는 `netbox.netbox` Ansible 컬렉션(Semaphore)으로 선언적 관리 →
(3) Prometheus http_sd·Ansible 동적 인벤토리·DNS 소스로 소비하는 순서를 권장한다.
