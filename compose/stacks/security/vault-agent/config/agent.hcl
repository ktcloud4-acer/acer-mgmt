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

# grafana compose env 파일. OAuth 클라이언트 시크릿은 더 이상 렌더하지 않고,
# oauth2-proxy identity header로 Grafana Auth Proxy 로그인을 통일한다.
template {
  contents    = "{{ with secret \"kv/data/mgmt/common\" }}ADMIN_PASSWORD={{ .Data.data.admin_password }}\n{{ end }}{{ with secret \"kv/data/mgmt/grafana\" }}SLACK_WEBHOOK_INFRA={{ .Data.data.slack_webhook_infra }}\n{{ end }}"
  destination = "/vault/secrets/observability/grafana.env"
  perms       = "0640"
}

# Alertmanager Slack 웹훅 (Alertmanager slack_api_url_file 로 직접 소비).
template {
  contents    = "{{ with secret \"kv/data/mgmt/alertmanager\" }}{{ .Data.data.slack_webhook_infra }}{{ end }}"
  destination = "/vault/secrets/alertmanager/slack_webhook_infra"
  perms       = "0640"
}

# --- n8n (전 팀 Prometheus 다이제스트) ---
template {
  contents    = "{{ with secret \"kv/data/mgmt/n8n\" }}N8N_ENCRYPTION_KEY={{ .Data.data.encryption_key }}\nDB_POSTGRESDB_PASSWORD={{ .Data.data.db_password }}\n{{ end }}{{ with secret \"kv/data/mgmt/grafana\" }}SLACK_WEBHOOK_INFRA={{ .Data.data.slack_webhook_infra }}\n{{ end }}"
  destination = "/vault/secrets/observability/n8n.env"
  perms       = "0640"
}

# --- elk (감사 저장소 보안 — W0) ---
# ES security/kibana_system/logstash_ingest 패스워드 + Kibana 암호화 키 2종을
# kv/mgmt/elk 에서 렌더한다. observability/elk 스택이 이 env 를 소비한다.
template {
  contents    = "{{ with secret \"kv/data/mgmt/elk\" }}ELK_ELASTIC_PASSWORD={{ .Data.data.elastic_password }}\nELK_KIBANA_PASSWORD={{ .Data.data.kibana_password }}\nELK_LOGSTASH_PASSWORD={{ .Data.data.logstash_password }}\nELK_KIBANA_ENCRYPTION_KEY={{ .Data.data.kibana_encryption_key }}\nELK_KIBANA_SO_ENCRYPTION_KEY={{ .Data.data.kibana_so_encryption_key }}\n{{ end }}"
  destination = "/vault/secrets/observability/elk.env"
  perms       = "0640"
}

# --- traefik (Cloudflare DNS-01 token) ---
template {
  contents    = "{{ with secret \"kv/data/mgmt/traefik\" }}CF_DNS_API_TOKEN={{ .Data.data.cf_dns_api_token }}\n{{ end }}"
  destination = "/vault/secrets/edge/traefik.env"
  perms       = "0640"
}

# --- keycloak ---
template {
  contents    = "{{ with secret \"kv/data/mgmt/keycloak\" }}KEYCLOAK_ADMIN_PASSWORD={{ .Data.data.admin_password }}\nKEYCLOAK_DB_PASSWORD={{ .Data.data.db_password }}\n{{ end }}"
  destination = "/vault/secrets/security/keycloak.env"
  perms       = "0640"
}

# --- oauth2-proxy (Traefik forward-auth backed by Keycloak) ---
template {
  contents    = "{{ with secret \"kv/data/mgmt/oauth2-proxy\" }}{{ .Data.data.client_secret }}{{ end }}"
  destination = "/vault/secrets/oauth2_proxy_client_secret"
  perms       = "0640"
}

template {
  contents    = "{{ with secret \"kv/data/mgmt/oauth2-proxy\" }}{{ .Data.data.cookie_secret }}{{ end }}"
  destination = "/vault/secrets/oauth2_proxy_cookie_secret"
  perms       = "0640"
}

# --- teleport (central access plane) ---
template {
  contents    = "{{ with secret \"kv/data/mgmt/teleport\" }}TELEPORT_OIDC_CLIENT_SECRET={{ .Data.data.oidc_client_secret }}\n{{ end }}"
  destination = "/vault/secrets/security/teleport.env"
  perms       = "0640"
}

# --- wazuh (host detection) ---
# The central stack and enrolling agents use distinct credentials. Values are
# rendered only to the runtime tmpfs; they never enter Compose files or Git.
template {
  contents    = "{{ with secret \"kv/data/mgmt/wazuh\" }}WAZUH_INDEXER_PASSWORD={{ .Data.data.indexer_password }}\nWAZUH_DASHBOARD_PASSWORD={{ .Data.data.dashboard_password }}\nWAZUH_API_PASSWORD={{ .Data.data.api_password }}\n{{ end }}"
  destination = "/vault/secrets/security/wazuh.env"
  perms       = "0640"
}

template {
  contents    = "{{ with secret \"kv/data/mgmt/wazuh\" }}WAZUH_REGISTRATION_PASSWORD={{ .Data.data.registration_password }}\n{{ end }}"
  destination = "/vault/secrets/security/wazuh-agent.env"
  perms       = "0640"
}

template {
  contents    = "{{ with secret \"kv/data/mgmt/teleport\" }}{{ .Data.data.tls_cert_pem }}{{ end }}"
  destination = "/vault/secrets/security/teleport/tls.crt"
  perms       = "0640"
}

template {
  contents    = "{{ with secret \"kv/data/mgmt/teleport\" }}{{ .Data.data.tls_key_pem }}{{ end }}"
  destination = "/vault/secrets/security/teleport/tls.key"
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
  contents    = "{{ with secret \"kv/data/mgmt/semaphore\" }}SEMAPHORE_DB_PASS={{ .Data.data.db_password }}\nSEMAPHORE_ACCESS_KEY_ENCRYPTION={{ .Data.data.access_key_encryption }}\nSEMAPHORE_COOKIE_HASH={{ .Data.data.cookie_hash }}\nSEMAPHORE_COOKIE_ENCRYPTION={{ .Data.data.cookie_encryption }}\nPOSTGRES_PASSWORD={{ .Data.data.db_password }}\n{{ end }}{{ with secret \"kv/data/mgmt/common\" }}SEMAPHORE_ADMIN_PASSWORD={{ .Data.data.admin_password }}\n{{ end }}{{ with secret \"kv/data/mgmt/cicd/semaphore-runner/aio\" }}SEMAPHORE_RUNNER_REGISTRATION_TOKEN={{ .Data.data.runner_registration_token }}\n{{ end }}"
  destination = "/vault/secrets/semaphore.env"
  perms       = "0640"
}

# semaphore compose env 파일. compose.yaml 이 기대하는 변수명으로 렌더한다.
template {
  contents    = "{{ with secret \"kv/data/mgmt/semaphore\" }}SEMAPHORE_DB_PASS={{ .Data.data.db_password }}\nSEMAPHORE_ACCESS_KEY_ENCRYPTION={{ .Data.data.access_key_encryption }}\nSEMAPHORE_COOKIE_HASH={{ .Data.data.cookie_hash }}\nSEMAPHORE_COOKIE_ENCRYPTION={{ .Data.data.cookie_encryption }}\nPOSTGRES_PASSWORD={{ .Data.data.db_password }}\n{{ end }}{{ with secret \"kv/data/mgmt/common\" }}SEMAPHORE_ADMIN_PASSWORD={{ .Data.data.admin_password }}\n{{ end }}{{ with secret \"kv/data/mgmt/cicd/semaphore-runner/aio\" }}SEMAPHORE_RUNNER_REGISTRATION_TOKEN={{ .Data.data.runner_registration_token }}\n{{ end }}"
  destination = "/vault/secrets/cicd/semaphore.env"
  perms       = "0640"
}

# Semaphore reads its Keycloak OIDC client secret from this file. Keep it out
# of the Compose env file so Docker inspect and task environments cannot expose it.
template {
  contents    = "{{ with secret \"kv/data/mgmt/semaphore\" }}{{ .Data.data.oidc_client_secret }}{{ end }}"
  destination = "/vault/secrets/semaphore_oidc_client_secret"
  perms       = "0640"
}

# Central Chaos Dashboard issuer kubeconfig. This file is read only by the
# Semaphore reconciliation job, which imports it as one encrypted task-scoped
# environment variable; it is not mounted into every Semaphore task.
template {
  contents    = "CHAOS_TOKEN_ISSUER_KUBECONFIG_B64={{ with secret \"kv/data/mgmt/chaos-dashboard-token-issuer\" }}{{ .Data.data.kubeconfig_b64 }}{{ end }}\n"
  destination = "/vault/secrets/cicd/chaos-dashboard-token-issuer.env"
  perms       = "0640"
}

# Per-cluster Chaos Dashboard issuers.  Each file is consumed only while the
# corresponding fixed Semaphore environment is reconciled; task output never
# includes this long-lived issuer credential.
template { contents = "CHAOS_TOKEN_ISSUER_KUBECONFIG_B64={{ with secret \"kv/data/mgmt/chaos/dashboard-token-issuers/nmg\" }}{{ .Data.data.kubeconfig_b64 }}{{ end }}\n" destination = "/vault/secrets/cicd/chaos-dashboard-token-issuers/nmg.env" perms = "0640" }
template { contents = "CHAOS_TOKEN_ISSUER_KUBECONFIG_B64={{ with secret \"kv/data/mgmt/chaos/dashboard-token-issuers/ggg\" }}{{ .Data.data.kubeconfig_b64 }}{{ end }}\n" destination = "/vault/secrets/cicd/chaos-dashboard-token-issuers/ggg.env" perms = "0640" }
template { contents = "CHAOS_TOKEN_ISSUER_KUBECONFIG_B64={{ with secret \"kv/data/mgmt/chaos/dashboard-token-issuers/khb\" }}{{ .Data.data.kubeconfig_b64 }}{{ end }}\n" destination = "/vault/secrets/cicd/chaos-dashboard-token-issuers/khb.env" perms = "0640" }
template { contents = "CHAOS_TOKEN_ISSUER_KUBECONFIG_B64={{ with secret \"kv/data/mgmt/chaos/dashboard-token-issuers/ljw\" }}{{ .Data.data.kubeconfig_b64 }}{{ end }}\n" destination = "/vault/secrets/cicd/chaos-dashboard-token-issuers/ljw.env" perms = "0640" }
template { contents = "CHAOS_TOKEN_ISSUER_KUBECONFIG_B64={{ with secret \"kv/data/mgmt/chaos/dashboard-token-issuers/oje\" }}{{ .Data.data.kubeconfig_b64 }}{{ end }}\n" destination = "/vault/secrets/cicd/chaos-dashboard-token-issuers/oje.env" perms = "0640" }

# Dedicated API key files for the five fixed k6 demo targets. Semaphore mounts
# this directory read-only; keys never enter a Semaphore project environment.
template { contents = "K6_DEMO_API_KEY={{ with secret \"kv/data/mgmt/k6/ggg\" }}{{ .Data.data.api_key }}{{ end }}\n" destination = "/vault/secrets/cicd/k6/ggg.env" perms = "0644" }
template { contents = "K6_DEMO_API_KEY={{ with secret \"kv/data/mgmt/k6/khb\" }}{{ .Data.data.api_key }}{{ end }}\n" destination = "/vault/secrets/cicd/k6/khb.env" perms = "0644" }
template { contents = "K6_DEMO_API_KEY={{ with secret \"kv/data/mgmt/k6/ljw\" }}{{ .Data.data.api_key }}{{ end }}\n" destination = "/vault/secrets/cicd/k6/ljw.env" perms = "0644" }
template { contents = "K6_DEMO_API_KEY={{ with secret \"kv/data/mgmt/k6/nmg\" }}{{ .Data.data.api_key }}{{ end }}\n" destination = "/vault/secrets/cicd/k6/nmg.env" perms = "0644" }
template { contents = "K6_DEMO_API_KEY={{ with secret \"kv/data/mgmt/k6/oje\" }}{{ .Data.data.api_key }}{{ end }}\n" destination = "/vault/secrets/cicd/k6/oje.env" perms = "0644" }

# gitlab compose env 파일.
template {
  contents    = "{{ with secret \"kv/data/mgmt/common\" }}ADMIN_PASSWORD={{ .Data.data.admin_password }}\n{{ end }}{{ with secret \"kv/data/mgmt/gitlab\" }}GITLAB_OIDC_CLIENT_SECRET={{ .Data.data.oidc_client_secret }}\n{{ end }}"
  destination = "/vault/secrets/cicd/gitlab.env"
  perms       = "0640"
}

# --- restic ---
template {
  contents    = "{{ with secret \"kv/data/mgmt/restic\" }}RESTIC_PASSWORD={{ .Data.data.password }}\nRESTIC_ACCESS_KEY={{ .Data.data.access_key }}\nRESTIC_SECRET_KEY={{ .Data.data.secret_key }}\n{{ end }}"
  destination = "/vault/secrets/restic.env"
  perms       = "0640"
}

# --- backup jobs: MinIO upload credentials ---
template {
  contents    = "{{ with secret \"kv/data/mgmt/minio\" }}MINIO_ROOT_USER={{ .Data.data.root_user }}\n{{ end }}{{ with secret \"kv/data/mgmt/common\" }}ADMIN_PASSWORD={{ .Data.data.admin_password }}\n{{ end }}"
  destination = "/vault/secrets/backup-minio.env"
  perms       = "0640"
}

template {
  contents    = "{{ with secret \"kv/data/mgmt/minio\" }}MINIO_ROOT_USER={{ .Data.data.root_user }}\n{{ end }}{{ with secret \"kv/data/mgmt/common\" }}ADMIN_PASSWORD={{ .Data.data.admin_password }}\n{{ end }}"
  destination = "/vault/secrets/backup/minio.env"
  perms       = "0640"
}

# --- backup jobs: offsite AWS S3 mirror credentials ---
template {
  contents    = "{{ with secret \"kv/data/mgmt/offsite-s3\" }}AWS_ACCESS_KEY_ID={{ .Data.data.access_key_id }}\nAWS_SECRET_ACCESS_KEY={{ .Data.data.secret_access_key }}\nAWS_REGION={{ .Data.data.region }}\nAWS_S3_BUCKET={{ .Data.data.bucket }}\n{{ end }}"
  destination = "/vault/secrets/offsite-s3.env"
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
