#!/usr/bin/env bash
# tests/e2e/aws.sh - the boundary on AWS (ADR 18), from inside the cluster
# aws/ made: a pod, and a pod on the node's own network, each try the ways
# out, beside a control that must work from the same place.
#
#   1. names: the cluster's own services resolve; this region's ECR endpoint
#      name resolves, to an address inside the VPC; a public name does not,
#      and a public resolver cannot be asked directly
#   2. addresses: ECR answers on 443 through its endpoint; nothing on the
#      internet does, by address, on 443 or on 53
#   3. the node itself: the same, from the host network
#
# Every refusal sits beside a control from the same pod, so a dead network
# cannot pass for a closed one. Needs REGISTRY, CLUSTER, REGION, VPC_CIDR and
# kubectl pointed at the cluster. Appends to $E2E_RESULTS (JSON) when set.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${REGISTRY:?}" "${CLUSTER:?}" "${REGION:?}" "${VPC_CIDR:?}"
digest="$(grep -E '^docker.io/library/busybox:' "$ROOT/airgap/images.txt" | sed 's/.*@//')"
BUSYBOX="$REGISTRY/$CLUSTER/busybox@$digest"
ECR_API="api.ecr.$REGION.amazonaws.com"
prefix="$(cut -d. -f1-2 <<<"${VPC_CIDR%/*}")."
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
pass "control: a pod starts from this run's ECR, through the endpoints, by digest ($BUSYBOX)"

inpod() { local pod="$1"; shift; kubectl -n probe exec "$pod" -- sh -c "$*" 2>&1; }
resolves() { inpod "$1" "nslookup $2 ${3:-}" >/dev/null; }
opens() { inpod "$1" "nc -w 5 $2 $3 </dev/null" >/dev/null; }

for pod in probe probe-node; do
  where="a pod"; [ "$pod" = probe-node ] && where="the node"

  step "$where: names"
  if [ "$pod" = probe ]; then
    if resolves "$pod" kubernetes.default.svc.cluster.local; then pass "control: $where resolves the cluster's own services"
    else fail "control: $where does not resolve kubernetes.default.svc.cluster.local, so nothing below says anything"; fi
  fi
  ecr="$(inpod "$pod" "nslookup $ECR_API" | sed -n 's/^Address: *//p' | grep -v ':53$' | head -1)"
  if [[ "$ecr" == "$prefix"* ]]; then pass "control: $where resolves $ECR_API to $ecr, inside the VPC, through its endpoint"
  else fail "control: $where resolved $ECR_API to '${ecr:-nothing}', not an address inside $VPC_CIDR"; fi
  if resolves "$pod" example.com; then fail "$where resolved example.com: a lookup leaves the VPC, with whatever a workload puts in the name"
  else pass "$where cannot resolve example.com (the resolver refuses names outside AWS)"; fi
  if resolves "$pod" example.com 8.8.8.8; then fail "$where reached a public resolver, 8.8.8.8, directly"
  else pass "$where cannot ask a public resolver directly (8.8.8.8)"; fi

  step "$where: addresses"
  if opens "$pod" "$ECR_API" 443; then pass "control: $where opens TCP to ECR on 443, through its endpoint"
  else fail "control: $where cannot open TCP to $ECR_API on 443, so the refusals below say nothing"; fi
  for target in 1.1.1.1:443 8.8.8.8:53 151.101.0.81:443; do
    if opens "$pod" "${target%:*}" "${target#*:}"; then fail "$where opened TCP to $target on the internet"
    else pass "$where opens no TCP to $target"; fi
  done
done

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
