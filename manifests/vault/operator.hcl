# The operator's token for the drills (tests/e2e/vault.sh), made by
# scripts/vault.sh install before it revokes the root token. It can change
# the roles, the key and the identities the drills plant and put back, and
# nothing in sys/ but the one policy the wrong-audience plant widens.
path "identity/entity/id/*" {
  capabilities = ["read", "update"]
}
path "identity/oidc/role/*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "identity/oidc/key/records" {
  capabilities = ["read", "update"]
}
path "identity/oidc/key/records/rotate" {
  capabilities = ["update"]
}
path "auth/kubernetes/role/*" {
  capabilities = ["read", "update"]
}
path "sys/policies/acl/records-caller" {
  capabilities = ["read", "update"]
}
