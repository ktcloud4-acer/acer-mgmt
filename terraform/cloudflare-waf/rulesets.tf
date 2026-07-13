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

# 간단 rate limit (Free 1 rule). Free 플랜은 period/mitigation_timeout=10 만 허용.
resource "cloudflare_ruleset" "ratelimit" {
  zone_id     = var.zone_id
  name        = "acer-waf-ratelimit"
  description = "간단 rate limit (Free 1 rule)"
  kind        = "zone"
  phase       = "http_ratelimit"

  rules {
    action      = "block"
    description = "IP당 10초당 50요청 초과 차단(Free 플랜 고정 window 10s)"
    expression  = "true"
    enabled     = true
    ratelimit {
      characteristics     = ["ip.src", "cf.colo.id"]
      period              = 10
      requests_per_period = 50
      mitigation_timeout  = 10
    }
  }
}

# Bot Fight Mode: Free 플랜에서는 cloudflare_bot_management API(Auth error 10000)로
# 관리 불가 → Cloudflare 대시보드 Security > Bots > Bot Fight Mode 토글로 수동 활성.
# (apply 검증 2026-07-13: Free 미지원 확인되어 IaC에서 제외.)
