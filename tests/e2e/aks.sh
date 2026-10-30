#!/usr/bin/env bash
# tests/e2e/aks.sh - the boundary on AKS (ADR 23), from inside the cluster
# aks/ made: a pod, and a pod on the node's own network, each try the ways
# out, beside a control that must work from the same place.
#
#   1. names: the cluster's own services resolve; the registry's name
#      resolves, to its private endpoint's addresses, from the network's own
#      zone; a public name does not, and a public resolver cannot be asked
#      directly
#   2. addresses: the registry answers on 443 through its private endpoint;
#      nothing on the internet does, by address, on 443 or on 53, and neither
#      does mcr.microsoft.com, where AKS's own images are published
#   3. the node itself: the same, from the host network
#   4. AKS's own images came through the registry's cache: the registry holds
#      them under aks-managed-repository/, read from the connected side
#
# Every refusal sits beside a control from the same pod, so a dead network
# cannot pass for a closed one. Needs REGISTRY, REGISTRY_NAME, INSIDE and
# REGISTRY_CIDR, az logged in as the run's identity, and kubectl pointed at
# the cluster. Appends to $E2E_RESULTS (JSON) when set.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${REGISTRY:?}" "${REGISTRY_NAME:?}" "${INSIDE:?}" "${REGISTRY_CIDR:?}"
digest="$(grep -E '^docker.io/library/busybox:' "$ROOT/airgap/images.txt" | sed 's/.*@//')"
# Under its original path in the run's registry, as everything inside is
# (scripts/inside.sh).
BUSYBOX="$INSIDE/docker.io/library/busybox@$digest"
# mcr.microsoft.com's address as the connected side sees it.
mcr="$(python3 -c 'import socket; print(socket.gethostbyname("mcr.microsoft.com"))')"
# within <range> <address>...: every address is in the range, and there is one
within() { [ "$#" -gt 1 ] && python3 -c 'import ipaddress, sys; n = ipaddress.ip_network(sys.argv[1]); sys.exit(0 if all(ipaddress.ip_address(a) in n for a in sys.argv[2:]) else 1)' "$@"; }
results=(); failed=0
pass() { results+=("PASS  $1"); printf '  PASS  %s\n' "$1"; }
fail() { results+=("FAIL  $1"); printf '  FAIL  %s\n' "$1"; failed=1; }
step() { printf '\n== %s\n' "$*"; }

kubectl create namespace probe --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: probe, namespace: probe}
spec:
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: c
      image: $BUSYBOX
      command: [sleep, "3600"]
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
---
apiVersion: v1
kind: Pod
metadata: {name: probe-node, namespace: probe}
spec:
  hostNetwork: true
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: c
      image: $BUSYBOX
      command: [sleep, "3600"]
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
EOF
if ! kubectl -n probe wait pod/probe pod/probe-node --for=condition=Ready --timeout=300s >/dev/null; then
  fail "the probes did not start: $(kubectl -n probe get events --sort-by=.lastTimestamp | tail -3 | tr -s ' ' | cut -c1-300)"
  printf '%s\n' "${results[@]}"; exit 1
fi
pass "control: a pod starts from this run's registry, through its private endpoint, by digest ($BUSYBOX)"

inpod() { local pod="$1"; shift; kubectl -n probe exec "$pod" -- sh -c "$*" 2>&1; }
# addresses <pod> <name> [server]: what the lookup answered, not the server's
# own address line. A refused name comes back with no address, so the answer
# is read, not nslookup's status.
addresses() { inpod "$1" "nslookup $2 ${3:-}" | sed -n 's/^Address:[[:space:]]*//p' | grep -v ':53$'; }
resolves() { [ -n "$(addresses "$@")" ]; }
opens() { inpod "$1" "nc -w 5 $2 $3 </dev/null" >/dev/null; }
# The node's processor, for the record: a sizing is read against the node it
# was measured on (ADR 18).
printf '  the node: %s, %s vCPU\n' "$(inpod probe "grep -m1 'model name' /proc/cpuinfo" | cut -d: -f2- | sed 's/^ *//')" "$(inpod probe nproc)"

for pod in probe probe-node; do
  where="a pod"; [ "$pod" = probe-node ] && where="the node"

  step "$where: names"
  if [ "$pod" = probe ]; then
    if resolves "$pod" kubernetes.default.svc.cluster.local; then pass "control: $where resolves the cluster's own services"
    else fail "control: $where does not resolve kubernetes.default.svc.cluster.local, so nothing below says anything"; fi
  fi
  got="$(addresses "$pod" "$REGISTRY" | sort -u | tr '\n' ' ')"
  # shellcheck disable=SC2086  # one argument per address
  if within "$REGISTRY_CIDR" $got; then
    pass "control: $where resolves $REGISTRY to ${got% }, its private endpoint, from the network's own zone"
  else fail "control: $where resolved $REGISTRY to '${got:-nothing}', not only to its private endpoint ($REGISTRY_CIDR)"; fi
  for name in example.com example.org; do
    if resolves "$pod" "$name"; then fail "$where resolved $name: a lookup leaves the network, with whatever a workload puts in the name"
    else pass "$where cannot resolve $name (the resolver policy refuses every name but the registry's and the network's own)"; fi
  done
  if resolves "$pod" example.com 8.8.8.8; then fail "$where reached a public resolver, 8.8.8.8, directly"
  else pass "$where cannot ask a public resolver directly (8.8.8.8)"; fi

  step "$where: addresses"
  if opens "$pod" "$REGISTRY" 443; then pass "control: $where opens TCP to $REGISTRY on 443, through its private endpoint"
  else fail "control: $where cannot open TCP to $REGISTRY on 443, so the refusals below say nothing"; fi
  for target in 1.1.1.1:443 8.8.8.8:53 151.101.0.81:443; do
    if opens "$pod" "${target%:*}" "${target#*:}"; then fail "$where opened TCP to $target, outside the network"
    else pass "$where opens no TCP to $target"; fi
  done
  if opens "$pod" "$mcr" 443; then fail "$where opened TCP to mcr.microsoft.com ($mcr:443): AKS's images need not have come through the registry"
  else pass "$where opens no TCP to mcr.microsoft.com ($mcr:443), where AKS's own images are published"; fi
done

step "AKS's own images"
cached="$(az acr repository list --name "$REGISTRY_NAME" -o tsv 2>/dev/null | grep -c '^aks-managed-repository/' || true)"
if [ "${cached:-0}" -gt 0 ]; then
  pass "control: AKS's own images came through the registry's cache: it holds $cached repositories under aks-managed-repository/"
else fail "the registry holds nothing under aks-managed-repository/: the node did not start from the cache"; fi

kubectl delete namespace probe --wait=false >/dev/null 2>&1
printf '\n'; printf '%s\n' "${results[@]}"
if [ -n "${E2E_RESULTS:-}" ]; then
  printf '%s\n' "${results[@]}" | python3 -c '
import json, os, sys
out = sys.argv[1]
d = json.load(open(out)) if os.path.exists(out) else {"checks": [], "measured": []}
d["checks"] += [{"name": l[6:].strip(), "passed": l.startswith("PASS")} for l in sys.stdin if l.strip()]
json.dump(d, open(out, "w"), indent=1)' "$E2E_RESULTS"
fi
exit "$failed"
