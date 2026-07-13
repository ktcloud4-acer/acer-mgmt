# Layer 1 custom rules — Free 플랜 5개 이하
resource "cloudflare_ruleset" "custom_fw" {
  zone_id     = var.zone_id
  name        = "acer-waf-custom"
  description = "portfolio WAF custom rules"
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  rules {
    action      = "managed_challenge"
    expression  = "(cf.threat_score gt 20)"
    description = "고위험 threat score challenge"
    enabled     = true
  }
  rules {
    action      = "block"
    expression  = "(http.user_agent contains \"sqlmap\") or (http.user_agent contains \"nikto\") or (http.user_agent contains \"nmap\")"
    description = "알려진 스캐너 UA 차단"
    enabled     = true
  }
  rules {
    action      = "block"
    expression  = "(http.request.uri.path contains \"/.git/\") or (http.request.uri.path contains \"/.env\") or (http.request.uri.path contains \"/wp-admin\")"
    description = "민감 경로 차단"
    enabled     = true
  }
  rules {
    action      = "block"
    expression  = "(not http.request.method in {\"GET\" \"POST\" \"PUT\" \"PATCH\" \"DELETE\" \"HEAD\" \"OPTIONS\"})"
    description = "비정상 HTTP 메서드 차단"
    enabled     = true
  }
}

# Cloudflare Free Managed Ruleset 실행
resource "cloudflare_ruleset" "managed_fw" {
  zone_id     = var.zone_id
  name        = "acer-waf-managed"
  description = "Cloudflare Free Managed Ruleset 실행"
  kind        = "zone"
  phase       = "http_request_firewall_managed"

  rules {
    action = "execute"
    action_parameters {
      id = "77454fe2d30c4220b5701f6fdfb893ba" # Cloudflare Managed Free Ruleset (imcherry5778.xyz, 실측 확인)
    }
    expression  = "true"
    description = "Free Managed Ruleset"
    enabled     = true
  }
}

# 간단 rate limit (Free 1 rule)
resource "cloudflare_ruleset" "ratelimit" {
  zone_id     = var.zone_id
  name        = "acer-waf-ratelimit"
  description = "간단 rate limit (Free 1 rule)"
  kind        = "zone"
  phase       = "http_ratelimit"

  rules {
    action      = "block"
    description = "IP당 분당 100요청 초과 차단"
    expression  = "true"
    enabled     = true
    ratelimit {
      characteristics     = ["ip.src", "cf.colo.id"]
      period              = 60
      requests_per_period = 100
      mitigation_timeout  = 60
    }
  }
}

# NOTE: `terraform validate` 통과 확인됨(provider v4.52.8, 스키마상 fight_mode
# 존재). 단, Free 플랜에서 이 리소스가 실제 apply 시에도 지원되는지는 본
# 작업(init/validate only, plan/apply 금지)에서 확인하지 못했다. apply 단계에서
# Free 플랜 미지원 오류가 발생하면 이 리소스를 제거하고 Cloudflare 대시보드
# Security > Bots > Bot Fight Mode 토글로 대체한다.
resource "cloudflare_bot_management" "bfm" {
  zone_id    = var.zone_id
  fight_mode = true
}
