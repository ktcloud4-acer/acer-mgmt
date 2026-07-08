# Vault Agent 설정 — AppRole auto-auth + 스택별 시크릿 파일 렌더.
# 참조: web-service 는 ESO(k8s), mgmt compose 는 이 Agent 로 통일.

vault {
  # 직접 내부 연결 → Vault 가 Agent 의 실제 소스 IP 를 보게 되어 CIDR 바인딩이 작동.
  address = "https://vault:8200"
  ca_cert = "/vault/tls/ca.crt"
}

auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path                   = "/vault/auth/role_id"
      secret_id_file_path                 = "/vault/auth/secret_id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = {
      path = "/vault/auth/.agent-token"
    }
  }
}

# grafana OAuth 시크릿 (GF_ 변수 → __FILE 로 소비).
template {
  contents    = "{{ with secret \"kv/data/mgmt/grafana\" }}{{ .Data.data.oauth_client_secret }}{{ end }}"
  destination = "/vault/secrets/grafana_oauth_client_secret"
  perms       = "0640"
}

# grafana admin 비밀번호 (공유값 kv/mgmt/common, GF_ 변수 → __FILE).
template {
  contents    = "{{ with secret \"kv/data/mgmt/common\" }}{{ .Data.data.admin_password }}{{ end }}"
  destination = "/vault/secrets/grafana_admin_password"
  perms       = "0640"
}

# SLACK 웹훅 (GF_ 변수 아님 → env_file 로 소비하므로 KEY=VALUE 형태로 렌더).
template {
  contents    = "SLACK_WEBHOOK_INFRA={{ with secret \"kv/data/mgmt/grafana\" }}{{ .Data.data.slack_webhook_infra }}{{ end }}\n"
  destination = "/vault/secrets/grafana.env"
  perms       = "0640"
}

# Alertmanager Slack 웹훅 (Alertmanager slack_api_url_file 로 직접 소비).
template {
  contents    = "{{ with secret \"kv/data/mgmt/alertmanager\" }}{{ .Data.data.slack_webhook_infra }}{{ end }}"
  destination = "/vault/secrets/alertmanager/slack_webhook_infra"
  perms       = "0640"
}

# Alertmanager Argo CD Slack 웹훅 (#argocd-알림).
template {
  contents    = "{{ with secret \"kv/data/mgmt/alertmanager\" }}{{ .Data.data.slack_webhook_argocd }}{{ end }}"
  destination = "/vault/secrets/alertmanager/slack_webhook_argocd"
  perms       = "0640"
}

# --- sonarqube (env_file, 컨테이너 변수명으로 렌더) ---
template {
  contents    = "{{ with secret \"kv/data/mgmt/sonarqube\" }}SONAR_JDBC_PASSWORD={{ .Data.data.db_password }}\nSONAR_AUTH_JWTBASE64HS256SECRET={{ .Data.data.jwt_secret }}\nPOSTGRES_PASSWORD={{ .Data.data.db_password }}\n{{ end }}"
  destination = "/vault/secrets/sonarqube.env"
  perms       = "0640"
}

# --- semaphore (semaphore + common(admin) 두 경로) ---
template {
  contents    = "{{ with secret \"kv/data/mgmt/semaphore\" }}SEMAPHORE_DB_PASS={{ .Data.data.db_password }}\nSEMAPHORE_ACCESS_KEY_ENCRYPTION={{ .Data.data.access_key_encryption }}\nSEMAPHORE_COOKIE_HASH={{ .Data.data.cookie_hash }}\nSEMAPHORE_COOKIE_ENCRYPTION={{ .Data.data.cookie_encryption }}\nPOSTGRES_PASSWORD={{ .Data.data.db_password }}\n{{ end }}{{ with secret \"kv/data/mgmt/common\" }}SEMAPHORE_ADMIN_PASSWORD={{ .Data.data.admin_password }}\n{{ end }}"
  destination = "/vault/secrets/semaphore.env"
  perms       = "0640"
}

# --- restic ---
template {
  contents    = "{{ with secret \"kv/data/mgmt/restic\" }}RESTIC_PASSWORD={{ .Data.data.password }}\nAWS_ACCESS_KEY_ID={{ .Data.data.access_key }}\nAWS_SECRET_ACCESS_KEY={{ .Data.data.secret_key }}\n{{ end }}"
  destination = "/vault/secrets/restic.env"
  perms       = "0640"
}

# --- supabase (stack .env 전체를 렌더: 시크릿=vault 참조, 설정=리터럴; 템플릿 파일 참조) ---
template {
  source      = "/vault/templates/supabase.env.ctmpl"
  destination = "/vault/secrets/supabase.env"
  perms       = "0640"
}

# --- harbor (config/*/env 5개 + secretkey; 값 동일 게이트 통과 후 컷오버) ---
template { source = "/vault/templates/harbor/core.env.ctmpl"          destination = "/vault/secrets/harbor/core.env"          perms = "0640" }
template { source = "/vault/templates/harbor/db.env.ctmpl"            destination = "/vault/secrets/harbor/db.env"            perms = "0640" }
template { source = "/vault/templates/harbor/jobservice.env.ctmpl"    destination = "/vault/secrets/harbor/jobservice.env"    perms = "0640" }
template { source = "/vault/templates/harbor/registryctl.env.ctmpl"   destination = "/vault/secrets/harbor/registryctl.env"   perms = "0640" }
template { source = "/vault/templates/harbor/trivy-adapter.env.ctmpl" destination = "/vault/secrets/harbor/trivy-adapter.env" perms = "0640" }
# secretkey 는 stateful 암호화 키 + harbor-core(uid10000) rw 마운트 → 동적 렌더/링크 금지.
# 값은 kv/mgmt/harbor 에 백업만 하고 라이브 파일(0600, harbor 소유)은 그대로 둔다.

# --- netbox (IPAM/CMDB; compose --env-file 로 소비, 컨테이너 변수명 렌더) ---
template {
  contents    = "{{ with secret \"kv/data/mgmt/netbox\" }}NETBOX_DB_PASSWORD={{ .Data.data.db_password }}\nNETBOX_REDIS_PASSWORD={{ .Data.data.redis_password }}\nNETBOX_REDIS_CACHE_PASSWORD={{ .Data.data.redis_cache_password }}\nNETBOX_SECRET_KEY={{ .Data.data.secret_key }}\nNETBOX_SUPERUSER_PASSWORD={{ .Data.data.superuser_password }}\nNETBOX_SUPERUSER_API_TOKEN={{ .Data.data.superuser_api_token }}\nNETBOX_OIDC_CLIENT_SECRET={{ .Data.data.oidc_client_secret }}\n{{ end }}"
  destination = "/vault/secrets/netbox.env"
  perms       = "0640"
}
