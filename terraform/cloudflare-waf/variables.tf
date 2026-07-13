variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = "Zone WAF 편집 권한 토큰 (Vault 주입)"
}

variable "zone_id" {
  type        = string
  description = "imcherry5778.xyz 의 Cloudflare Zone ID"
}
