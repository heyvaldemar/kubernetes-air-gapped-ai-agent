# Vault's server configuration (ADR 24). Not dev mode: integrated storage on
# the pod's volume, TLS on the listener, sealed until three of five shares
# unseal it (scripts/vault.sh install). One node: the cluster address is the
# pod's own loopback.
ui            = false
disable_mlock = true
api_addr      = "https://vault.vault.svc.cluster.local:8200"
cluster_addr  = "https://127.0.0.1:8201"

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "127.0.0.1:8201"
  tls_cert_file   = "/vault/tls/tls.crt"
  tls_key_file    = "/vault/tls/tls.key"
  tls_min_version = "tls12"
}

storage "raft" {
  path    = "/vault/data"
  node_id = "vault-0"
}
