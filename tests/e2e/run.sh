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
#   7. a pod resolves the registry's own name, which is how anything in the
#      cluster that reads a registry itself (an admission controller fetching
#      a signature) finds it
#   8. the registry speaks only TLS: a plain-HTTP request is refused
#   9. admission refuses a pod that mounts model weights nobody signed, or
#      signed by a key the cluster does not trust, or named by tag, or from
#      anywhere but the models path inside; and admits the signed model
#
# The model's own answers are judged by scripts/evals.sh, from the agent's
# side of the network policies.
#
# Writes $E2E_RESULTS (one JSON document) when set, for the status workflow.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLUSTER="${CLUSTER:-air-gapped}"
NODE="$(kind get nodes --name "$CLUSTER" | head -n 1)"
BUSYBOX="$(grep -E '^docker.io/library/busybox:' "$ROOT/airgap/images.txt")"
STATE="$ROOT/.cache/airgap"
REG=registry.boundary.internal:5000
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

step "7. a pod resolves the registry's own name"
want="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' kind-registry)"
if kubectl exec probe -- nslookup -timeout=3 registry.boundary.internal 2>/dev/null | sed -n '/^Name:/,$p' | grep -q "Address: $want"; then
  pass "a pod resolves registry.boundary.internal to the registry inside ($want)"
else
  fail "a pod does not resolve registry.boundary.internal to $want"
fi

step "8. the registry speaks only TLS"
code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://registry.boundary.internal:5000/v2/ || true)"
if [ "$code" = 200 ]; then
  fail "the registry answered plain HTTP with 200"
else
  pass "the registry refuses plain HTTP (got ${code:-no answer})"
fi

step "9. admission refuses model weights it cannot vouch for"
mount_pod() {  # mount_pod <name> <image reference>: a pod that mounts it as an image volume, server-side dry run
  kubectl apply --dry-run=server -f - 2>&1 <<YAML
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: inference}
spec:
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: c
      image: $BUSYBOX
      command: [sleep, "3600"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
      volumeMounts: [{name: model, mountPath: /models, readOnly: true}]
  volumes:
    - name: model
      image: {reference: "$2", pullPolicy: IfNotPresent}
YAML
}
refused() {  # refused <what> <image reference> <expected message>
  local out; out="$(mount_pod "$3-x" "$2" || true)"
  if grep -q "denied" <<<"$out" && grep -q "$4" <<<"$out"; then pass "refused: $1"; else fail "not refused as expected: $1: $(head -c 300 <<<"$out")"; fi
}
model="$(kubectl -n inference get deployment llama -o jsonpath='{.spec.template.spec.volumes[0].image.reference}')"
refused "weights nobody signed" "$REG/models/plant-unsigned@$(cat "$STATE/plant-unsigned.digest")" unsigned "signed with the operator's key"
refused "weights signed by a key the cluster does not trust" "$REG/models/plant-stranger@$(cat "$STATE/plant-stranger.digest")" stranger "signed with the operator's key"
refused "the signed model named by tag, not digest" "$REG/models/granite-4.0-1b:q4_k_m" bytag "by digest"
refused "an image volume from outside the models path" "$BUSYBOX" elsewhere "only from registry.boundary.internal:5000/models"
if out="$(mount_pod control "$model")"; then pass "admitted: the signed model, by digest"; else fail "the signed model was refused: $(head -c 300 <<<"$out")"; fi

kubectl delete pod probe --wait=false >/dev/null 2>&1
printf '\n'; printf '%s\n' "${results[@]}"
if [ -n "${E2E_RESULTS:-}" ]; then
  printf '%s\n' "${results[@]}" | python3 -c '
import json, sys
checks = [{"name": l[6:].strip(), "passed": l.startswith("PASS")} for l in sys.stdin if l.strip()]
json.dump({"checks": checks, "measured": []}, open(sys.argv[1], "w"), indent=1)' "$E2E_RESULTS"
fi
exit "$failed"
