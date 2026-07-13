# Cloudflare edge WAF (Terraform, Free 플랜)

`imcherry5778.xyz` 존에 Cloudflare Free 플랜 리소스로 edge WAF(Layer 2 심층방어의
바깥 계층)를 IaC로 관리한다. Origin(traefik + Coraza WASM)과 함께 2계층 방어를
구성하며, 자세한 아키텍처/롤아웃 순서는
`docs/superpowers/plans/2026-07-13-waf-coraza-cloudflare.md` (acer-argocd repo,
Part C)를 참고한다.

## 리소스 구성

| 파일 | 리소스 | phase | 설명 |
|---|---|---|---|
| `rulesets.tf` | `cloudflare_ruleset.custom_fw` | `http_request_firewall_custom` | Custom rules 4개(Free 한도 ≤5): threat score challenge, 스캐너 UA 차단, 민감 경로 차단, 비정상 HTTP 메서드 차단 |
| `rulesets.tf` | `cloudflare_ruleset.managed_fw` | `http_request_firewall_managed` | Cloudflare Managed Free Ruleset(`77454fe2d30c4220b5701f6fdfb893ba`) execute |
| `rulesets.tf` | `cloudflare_ruleset.ratelimit` | `http_ratelimit` | IP당 분당 100요청 초과 차단(Free 한도 1개) |
| `rulesets.tf` | `cloudflare_bot_management.bfm` | (zone 설정) | Bot Fight Mode 활성화 |

## 토큰

- **기존 `CF_DNS_API_TOKEN`을 재사용**한다 — 별도 WAF 전용 토큰을 새로 발급하지
  않는다. 2026-07-13 실측으로 read+edit+zone 권한이 이 토큰에 이미 있음을
  확인했다.
- 토큰 값은 Vault `kv/mgmt/traefik` 시크릿의 `cf_dns_api_token` 필드에 있다.
- mgmt 서버에서는 traefik 컨테이너 환경변수로도 동일 값이 주입되어 있어
  아래처럼 재사용할 수 있다:

  ```bash
  export TF_VAR_cloudflare_api_token=$(ssh -i ~/.ssh/acer.pem user1@acer-mgmt \
    'docker inspect traefik --format "{{range .Config.Env}}{{println .}}{{end}}" \
     | grep ^CF_DNS_API_TOKEN= | cut -d= -f2-')
  export TF_VAR_zone_id=88a4ef16a8b524e9a4a048017423862a
  ```

- 토큰 값, `terraform.tfvars`, `*.tfstate`는 **절대 git에 커밋하지 않는다**
  (`.gitignore` 참고). `terraform.tfvars.example`은 비밀이 아닌 `zone_id`만
  실값으로 채워 두고, 토큰 자리는 placeholder로 남긴다.

## 실행법

```bash
cd terraform/cloudflare-waf
terraform init
terraform fmt
terraform validate

# apply 하려면 위 "토큰" 절차로 TF_VAR_* 를 export 한 뒤:
terraform plan
terraform apply
```

`init`/`fmt`/`validate`는 토큰·네트워크 접근이 필요 없다. `plan`/`apply`는
Cloudflare API 접근과 유효한 토큰이 필요하므로, 이 리포지토리를 초기 스캐폴딩한
작업(본 커밋)에서는 **의도적으로 실행하지 않았다**(게이트됨 — 토큰 준비 후
운영자가 직접 수행).

## v4 provider 스키마 조정 사항

- `cloudflare` provider를 `~> 4.40`으로 핀했고, 실제 설치된 버전은
  `4.52.8`이다(`terraform init` 시점 기준).
- `terraform validate`를 `cloudflare_bot_management.bfm`(`fight_mode = true`
  포함) 리소스가 있는 상태로 실행한 결과 **성공**했다 — v4.52.8 스키마에
  `fight_mode` 필드가 존재하므로 별도 조정 없이 계획서 원문 그대로 유지했다.
  단, Free 플랜에서 이 리소스가 apply 시점에도 실제로 지원되는지는 본 작업
  범위(`init`/`validate`만, `plan`/`apply` 금지)에서 확인하지 못했다. 만약
  향후 apply 시 Free 플랜 미지원으로 오류가 나면, 이 리소스를 제거하고
  **Cloudflare 대시보드 Security → Bots → Bot Fight Mode 토글**로 대체한다
  (근거: Free 플랜은 Bot Fight Mode를 대시보드 토글로 기본 제공하며, Terraform
  리소스 경유가 필수는 아니다).
- 그 외 `cloudflare_ruleset` 기반 리소스(custom/managed/ratelimit)는 모두
  `terraform validate` 통과를 확인했다.

## Free 플랜 한계 (초과 리소스 추가 금지)

- Custom rules ≤ 5개 (`custom_fw`에서 4개 사용 중, 여유 1개)
- Rate limit rule 1개만 (`ratelimit`에서 이미 사용)
- Logpush 불가

## ⚠️ state 관리 (2026-07-13 적용 후)
- 이 모듈은 **로컬 state**로 apply됨(custom_fw/managed_fw/ratelimit 3 리소스 live). 
- 부트스트랩 state 백업: `/home/imcherry/tfstate/cloudflare-waf/terraform.tfstate` (worktree 유실 대비).
- **권고**: 프로덕션은 원격 backend(MinIO S3 등)로 이관 후 `terraform init -migrate-state`. 예:
  ```
  terraform { backend "s3" { bucket="tfstate" key="cloudflare-waf.tfstate" endpoint="<minio>" ... skip_credentials_validation=true } }
  ```
- 토큰은 Vault `kv/mgmt/traefik.cf_dns_api_token`에서 `TF_VAR_cloudflare_api_token`으로 주입, `TF_VAR_zone_id=88a4ef16a8b524e9a4a048017423862a`.
