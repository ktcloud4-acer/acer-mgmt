ui = true

api_addr      = "https://vault.imcherry5778.xyz"
cluster_addr  = "http://vault:8201"
disable_mlock = true

storage "raft" {
  path    = "/vault/data"
  node_id = "mgmt-vault-1"
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = 1
}

telemetry {
  prometheus_retention_time = "30s"
  disable_hostname          = true
}
