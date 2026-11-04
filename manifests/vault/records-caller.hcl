# The MCP server's one right in Vault (ADR 24): read a records credential.
# Nothing else, not even the default policy's lookup of its own token.
path "identity/oidc/token/records-api" {
  capabilities = ["read"]
}
