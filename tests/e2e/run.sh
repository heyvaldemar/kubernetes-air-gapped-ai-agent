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
#  10. everything inside came in one signed file: the registry inside held
#      nothing when the bundle was loaded, it holds exactly what the bundle
#      carried, and a bundle changed by one byte is refused and loads nothing
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
model="$(kubectl -n inference get deployment llama -o jsonpath='{.spec.template.spec.volumes[0].image.reference}')"
for plant in "$ROOT"/tests/e2e/plants/*.yaml; do
  name="$(basename "$plant" .yaml)"
  expect="$(sed -n 's/^# expect: //p' "$plant")"
  out="$(sed -e "s#@BUSYBOX@#$BUSYBOX#g" -e "s#@MODEL@#$model#g" -e "s#@MODEL_TAG@#${model%@*}:q4_k_m#g" \
             -e "s#@UNSIGNED@#$REG/models/plant-unsigned@$(cat "$STATE/plant-unsigned.digest")#g" \
             -e "s#@STRANGER@#$REG/models/plant-stranger@$(cat "$STATE/plant-stranger.digest")#g" "$plant" \
         | kubectl apply --dry-run=server -f - 2>&1)"; rc=$?
  if [ "$expect" = admitted ]; then
    if [ $rc -eq 0 ]; then pass "$name: admitted"; else fail "$name was refused: $(head -c 300 <<<"$out")"; fi
  elif [ $rc -ne 0 ] && grep -qF "$expect" <<<"$out"; then
    pass "$name: refused ($expect)"
  else
    fail "$name: expected a refusal saying '$expect', got (rc=$rc): $(head -c 300 <<<"$out")"
  fi
done

step "10. everything inside came in one signed file"
CA="$STATE/ca.crt"
held() {  # every repo:tag@digest the registry inside holds
  local repo tag
  for repo in $(curl -fsS --cacert "$CA" "https://$REG/v2/_catalog?n=10000" | jq -r '.repositories[]'); do
    for tag in $(curl -fsS --cacert "$CA" "https://$REG/v2/$repo/tags/list" | jq -r '.tags[]?'); do
      printf '%s:%s@%s\n' "$repo" "$tag" "$(oras manifest fetch --ca-file "$CA" --descriptor "$REG/$repo:$tag" | jq -r .digest)"
    done
  done | sort
}
carried() {  # every repo:tag@digest in the bundle that was loaded
  local index layout
  find "$STATE/bundle.inside/oci" -name index.json | sort | while IFS= read -r index; do
    layout="$(dirname "$index")"
    jq -r --arg r "${layout#"$STATE/bundle.inside/oci/"}" \
      '.manifests[] | select(.annotations["org.opencontainers.image.ref.name"]) | "\($r):\(.annotations["org.opencontainers.image.ref.name"])@\(.digest)"' "$index"
  done | sort
}
if grep -qx 'repositories_before=0' "$STATE/bundle.loaded" 2>/dev/null; then
  pass "the registry inside held nothing when the bundle was loaded"
else
  fail "the registry inside was not empty when the bundle was loaded: $(tr '\n' ' ' <"$STATE/bundle.loaded" 2>/dev/null)"
fi
now="$(held)"
if [ -n "$now" ] && [ "$now" = "$(carried)" ]; then
  pass "it holds exactly what the bundle carried ($(grep -c . <<<"$now") tags, by digest)"
else
  fail "what the registry holds differs from what the bundle carried: $(diff <(carried) <(echo "$now") | head -5 | tr '\n' ' ')"
fi
cp "$STATE/bundle.tar" "$STATE/bundle.tampered" && cp "$STATE/bundle.tar.sigstore.json" "$STATE/bundle.tampered.sigstore.json"
printf 'X' | dd of="$STATE/bundle.tampered" bs=1 seek=4096 conv=notrunc 2>/dev/null
cp "$STATE/bundle.loaded" "$STATE/bundle.loaded.kept"
if ! BUNDLE="$STATE/bundle.tampered" "$ROOT/scripts/bundle.sh" load >/dev/null 2>&1 && [ "$(held)" = "$now" ]; then
  pass "a bundle changed by one byte is refused, and loads nothing"
else
  fail "a bundle changed by one byte was not refused, or changed the registry"
fi
mv "$STATE/bundle.loaded.kept" "$STATE/bundle.loaded"
rm -f "$STATE/bundle.tampered" "$STATE/bundle.tampered.sigstore.json"

kubectl delete pod probe --wait=false >/dev/null 2>&1
printf '\n'; printf '%s\n' "${results[@]}"
if [ -n "${E2E_RESULTS:-}" ]; then
  printf '%s\n' "${results[@]}" | python3 -c '
import json, sys
checks = [{"name": l[6:].strip(), "passed": l.startswith("PASS")} for l in sys.stdin if l.strip()]
json.dump({"checks": checks, "measured": []}, open(sys.argv[1], "w"), indent=1)' "$E2E_RESULTS"
fi
exit "$failed"
