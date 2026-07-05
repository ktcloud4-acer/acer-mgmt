ui = true

api_addr      = "https://vault.imcherry5778.xyz"
cluster_addr  = "https://vault:8201"
disable_mlock = false

storage "raft" {
  path    = "/vault/data"
  node_id = "mgmt-vault-1"
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_cert_file   = "/vault/tls/server.crt"
  tls_key_file    = "/vault/tls/server.key"
  tls_min_version = "tls13"
}

telemetry {
  prometheus_retention_time = "30s"
  disable_hostname          = true
}
