#!/usr/bin/env bash
# vault.sh <install|unseal|keys|release> - Vault Community inside the boundary, the
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
#   release  before a cloud cluster is destroyed: Vault and its claim
#            deleted, and the volume behind it gone, which a destroy would
#            leave (no Terraform state holds it)
#
# The CA's key, the certificate's key, the shares and the operator's token
# stay in .cache/airgap/vault/ on this machine, mode 600, and are never
# printed or passed as an argument.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$ROOT/.cache/airgap/vault"
say() { printf '== %s\n' "$*"; }
# Each class on stdin (a StorageClass or a list of them), its provisioner,
# and the annotations that mark it the default, or none.
DEFAULTS='
import json, sys
doc = json.load(sys.stdin)
for c in doc.get("items", [doc]):
    marks = ", ".join("%s=%s" % kv for kv in sorted((c["metadata"].get("annotations") or {}).items()) if "default-class" in kv[0])
    print("%s (%s), marked the default by: %s" % (c["metadata"]["name"], c["provisioner"], marks or "no annotation"))'

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
  say "Vault's certificate, from a CA made for this run; the MCP server is the only client given the CA"
}

case "${1:-}" in
  install)
    # Vault's claim names no class: the cluster gives it one, kind's
    # default, aws/storage-class.yaml on EKS, GKE's own. Ask the claim which,
    # not the classes' annotations: GKE runs 42458041663 and 42484106156 found
    # no class with either default annotation when this looked, and then
    # provisioned the claim with pd.csi.storage.gke.io. Kubernetes also gives
    # a claim made with no class the default that comes after it. With no
    # class after two minutes the pod would wait for ever; say so then.
    sc=""
    for _ in $(seq 1 60); do
      sc="$(kubectl -n vault get pvc data-vault-0 -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)"
      [ -n "$sc" ] && break
      sleep 2
    done
    if [ -z "$sc" ]; then
      kubectl get storageclass -o json | python3 -c "$DEFAULTS" >&2 || true
      echo "vault: Vault's claim has no StorageClass after 120 s, so its volume would never be made (ADR 24)" >&2
      exit 1
    fi
    say "Vault's volume from StorageClass $(kubectl get storageclass "$sc" -o json | python3 -c "$DEFAULTS")"
    tls
    python3 "$ROOT/scripts/vault_api.py" install
    say "Vault's claim: $(kubectl -n vault get pvc data-vault-0 -o jsonpath='{.spec.storageClassName}, {.status.capacity.storage}, volume {.spec.volumeName}')"
    ;;
  release)
    if ! kubectl get namespace vault >/dev/null 2>&1; then say "no Vault here: nothing to release"; exit 0; fi
    pvs="$(kubectl -n vault get pvc -o jsonpath='{.items[*].spec.volumeName}')"
    kubectl -n vault delete statefulset vault --ignore-not-found --cascade=foreground --timeout=180s >/dev/null
    kubectl -n vault delete pvc --all --timeout=180s >/dev/null
    for pv in $pvs; do
      kubectl wait --for=delete "pv/$pv" --timeout=300s >/dev/null 2>&1 \
        || { kubectl get pv "$pv" -o wide >&2 || true; echo "vault: $pv still there after 300 s" >&2; exit 1; }
    done
    say "Vault and its claim deleted, and the volume behind it gone: ${pvs:-none}"
    ;;
  unseal|keys)
    python3 "$ROOT/scripts/vault_api.py" "$1"
    ;;
  *) echo "usage: vault.sh <install|unseal|keys|release>" >&2; exit 2 ;;
esac
