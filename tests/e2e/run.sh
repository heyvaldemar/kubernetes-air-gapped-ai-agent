#!/usr/bin/env bash
# tests/e2e/run.sh - prove the boundary, on a cluster scripts/airgap.sh has
# closed. Each check states what it proves; the run fails if any outcome
# differs from what the boundary promises.
#
#   1. a pod reaches no address outside, by IP (1.1.1.1), so this is not
#      just DNS failing
#   2. a pod resolves no outside name
#   3. the node resolves no outside name: Docker's DNS forwarding, which
#      the firewall rule does not cover, is closed too
#   4. the node reaches no address outside, by IP
#   5. the node cannot pull an image that is not inside the boundary, by
#      its original name: the mirror has nothing, and upstream is cut
#   6. an image that is inside comes up by its original name and digest,
#      served from the registry inside, and is the pod the checks above ran in
#
# Writes $E2E_RESULTS (one JSON document) when set, for the status workflow.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLUSTER="${CLUSTER:-air-gapped}"
NODE="$(kind get nodes --name "$CLUSTER" | head -n 1)"
BUSYBOX="$(grep -E '^docker.io/library/busybox:' "$ROOT/airgap/images.txt")"
results=(); failed=0
pass() { results+=("PASS  $1"); printf '  PASS  %s\n' "$1"; }
fail() { results+=("FAIL  $1"); printf '  FAIL  %s\n' "$1"; failed=1; }
step() { printf '\n== %s\n' "$*"; }

step "6. an image inside the boundary, by its original name and digest"
kubectl delete pod probe --ignore-not-found --wait=true >/dev/null 2>&1
kubectl run probe --image="$BUSYBOX" --restart=Never --image-pull-policy=Always --command -- sleep 3600 >/dev/null
if kubectl wait --for=condition=Ready pod/probe --timeout=120s >/dev/null 2>&1; then
  pass "$BUSYBOX came up, pulled through the mirror inside"
else
  fail "the probe pod did not start: $(kubectl get pod probe -o jsonpath='{.status.containerStatuses[0].state.waiting.message}' 2>&1 | head -c 300)"
fi

step "1. a pod reaches no address outside"
if kubectl exec probe -- wget -T 5 -q -O /dev/null http://1.1.1.1 >/dev/null 2>&1; then
  fail "a pod reached 1.1.1.1"
else
  pass "a pod cannot reach 1.1.1.1"
fi

step "2. a pod resolves no outside name"
if out="$(kubectl exec probe -- nslookup -timeout=3 example.com 2>&1)" && grep -qE '^Address: [0-9]' <<<"$(sed -n '/^Name:/,$p' <<<"$out")"; then
  fail "a pod resolved example.com: $(tr '\n' ' ' <<<"$out" | head -c 200)"
else
  pass "a pod cannot resolve example.com"
fi
if kubectl exec probe -- nslookup -timeout=3 kubernetes.default.svc.cluster.local >/dev/null 2>&1; then
  pass "a pod still resolves cluster names"
else
  fail "a pod cannot resolve kubernetes.default.svc.cluster.local: CoreDNS is broken, not closed"
fi

step "3. the node resolves no outside name"
if docker exec "$NODE" getent hosts example.com >/dev/null 2>&1; then
  fail "the node resolved example.com"
else
  pass "the node cannot resolve example.com"
fi

step "4. the node reaches no address outside"
if docker exec "$NODE" curl -s -m 5 -o /dev/null https://1.1.1.1 2>/dev/null; then
  fail "the node reached 1.1.1.1"
else
  pass "the node cannot reach 1.1.1.1"
fi

step "5. the node pulls nothing that is not inside"
if docker exec "$NODE" timeout 60 crictl pull docker.io/library/alpine:3.20 >/dev/null 2>&1; then
  fail "the node pulled docker.io/library/alpine:3.20, which is not inside the boundary"
else
  pass "the node cannot pull docker.io/library/alpine:3.20 (not inside the boundary)"
fi

kubectl delete pod probe --wait=false >/dev/null 2>&1
printf '\n'; printf '%s\n' "${results[@]}"
if [ -n "${E2E_RESULTS:-}" ]; then
  printf '%s\n' "${results[@]}" | python3 -c '
import json, sys
checks = [{"name": l[6:].strip(), "passed": l.startswith("PASS")} for l in sys.stdin if l.strip()]
json.dump({"checks": checks, "measured": []}, open(sys.argv[1], "w"), indent=1)' "$E2E_RESULTS"
fi
exit "$failed"
