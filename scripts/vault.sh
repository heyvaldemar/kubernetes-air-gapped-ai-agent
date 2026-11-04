#!/usr/bin/env bash
# vault.sh <install|unseal|keys> - Vault Community inside the boundary, the
# issuer of the records credential (ADR 24). scripts/tools.sh runs install
# after it applies the manifests.
#
#   install  a CA made for this run and Vault's certificate from it (the
#            names the MCP server and the port-forward use), as the Secret
#            vault/vault-tls, and the CA alone as mcp/vault-ca, the one
#            place that trusts it; then scripts/vault_api.py install:
#            initialise with five shares, unseal with three, configure from
#            manifests/vault/, make the operator's token, revoke the root
#            token, and write Vault's public key set for the records service
#   unseal   after Vault's pod restarted: three of the shares again
#   keys     Vault's public key set into the records service's ConfigMap
#            again, after a rotation
#
# The CA's key, the certificate's key, the shares and the operator's token
# stay in .cache/airgap/vault/ on this machine, mode 600, and are never
# printed or passed as an argument.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$ROOT/.cache/airgap/vault"
say() { printf '== %s\n' "$*"; }

tls() {
  mkdir -p "$STATE"
  chmod 700 "$STATE"
  if [ ! -s "$STATE/ca.crt" ]; then
    (umask 077
     printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n' >"$STATE/ca.ext"
     openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=vault CA" \
       -keyout "$STATE/ca.key" -out "$STATE/ca.csr" 2>/dev/null
     openssl x509 -req -in "$STATE/ca.csr" -signkey "$STATE/ca.key" -days 30 -extfile "$STATE/ca.ext" \
       -out "$STATE/ca.crt" 2>/dev/null
     printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\nsubjectAltName=DNS:vault.vault.svc.cluster.local,DNS:vault.vault.svc,IP:127.0.0.1\n' >"$STATE/tls.ext"
     openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=vault.vault.svc" \
       -keyout "$STATE/tls.key" -out "$STATE/tls.csr" 2>/dev/null
     openssl x509 -req -in "$STATE/tls.csr" -CA "$STATE/ca.crt" -CAkey "$STATE/ca.key" -CAcreateserial -days 30 \
       -extfile "$STATE/tls.ext" -out "$STATE/tls.crt" 2>/dev/null)
  fi
  kubectl -n vault create secret generic vault-tls --from-file=tls.crt="$STATE/tls.crt" \
    --from-file=tls.key="$STATE/tls.key" --from-file=ca.crt="$STATE/ca.crt" --dry-run=client -o json | kubectl apply -f - >/dev/null
  kubectl -n mcp create configmap vault-ca --from-file=ca.crt="$STATE/ca.crt" --dry-run=client -o json | kubectl apply -f - >/dev/null
  say "Vault's certificate, from a CA made for this run; the CA trusted by the MCP server alone"
}

case "${1:-}" in
  install)
    tls
    python3 "$ROOT/scripts/vault_api.py" install
    ;;
  unseal|keys)
    python3 "$ROOT/scripts/vault_api.py" "$1"
    ;;
  *) echo "usage: vault.sh <install|unseal|keys>" >&2; exit 2 ;;
esac
