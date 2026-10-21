#!/usr/bin/env bash
# tests/e2e/run.sh - prove the boundary, on a cluster scripts/airgap.sh has
# closed. Each check states what it proves; the run fails if any outcome
# differs from what the boundary promises.
#
#   1. a pod reaches no address outside, by IP (1.1.1.1), so this is not
#      just DNS failing; beside it, the same pod reaches the registry inside,
#      so a dead network cannot pass for a closed one
#  1b. nor any other way a pod could try: other TCP ports, DNS over UDP
#      straight to a public resolver, the cloud's metadata address, and the
#      host itself, by any port or its resolver. IPv6 is measured, not gated:
#      the runner has no IPv6 route to test it against
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
#      anywhere but the models path inside, or with no AI-BOM, or with an
#      AI-BOM that lists any licence the site does not allow, a model with
#      none, or an SPDX expression; and admits the signed model with its
#      AI-BOM, and one whose expression was concluded to an allowed id. It
#      also refuses a pod whose image the bundle did not carry, by a digest
#      of its own or by tag
#  11. nothing that runs came from anywhere else: every pod outside the node
#      image's own namespaces runs images whose digests the bundle carried
#  10. everything inside came in one signed file: the registry inside held
#      nothing when the bundle was loaded, it holds exactly what the bundle
#      carried, and a bundle changed by one byte is refused and loads nothing
#  12. only the loader writes to the registry inside: a push with no
#      password, or a wrong one, is refused; with the loader's, it starts
#      (the control) and is cancelled. Reads need none: the nodes pull, and
#      checks 6 and 10 read, with no credential (ADR 2)
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
results=(); measured=(); failed=0
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
# The control first: the same pod, the same tool, an address inside that
# must answer. Without it, a pod whose network is broken would pass every
# refusal below.
reach() { kubectl exec probe -- nc -w 5 "$1" "$2" </dev/null >/dev/null 2>&1; }
if reach registry.boundary.internal 5000; then
  pass "control: the probe pod opens a connection to the registry inside (TCP 5000)"
else
  fail "control: the probe pod cannot reach the registry inside, so its refusals below prove nothing"
fi
if kubectl exec probe -- wget -T 5 -q -O /dev/null http://1.1.1.1 >/dev/null 2>&1; then
  fail "a pod reached 1.1.1.1"
else
  pass "a pod cannot reach 1.1.1.1"
fi

step "1b. nor any other way out a pod could try"
for target in 1.1.1.1:443 8.8.8.8:53 9.9.9.9:853 140.82.112.3:22; do
  if reach "${target%:*}" "${target#*:}"; then fail "a pod opened TCP to $target"; else pass "a pod cannot open TCP to $target"; fi
done
if out="$(kubectl exec probe -- nslookup -timeout=3 example.com 1.1.1.1 2>&1)" && grep -qE '^Address: [0-9]' <<<"$(sed -n '/^Name:/,$p' <<<"$out")"; then
  fail "a pod resolved example.com by asking 1.1.1.1 over UDP directly"
else
  pass "a pod cannot ask a public resolver directly (DNS over UDP to 1.1.1.1)"
fi
# The metadata address answers on the runner itself (Azure's instance
# metadata service): from the host it must, from a pod it must not. Only
# the status code is read, never the body.
host_md="$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H 'Metadata: true' 'http://169.254.169.254/metadata/instance?api-version=2021-02-01' || true)"
if kubectl exec probe -- wget -T 5 -q -O /dev/null http://169.254.169.254/ >/dev/null 2>&1 || reach 169.254.169.254 80; then
  fail "a pod reached the metadata address 169.254.169.254"
elif [ "$host_md" = 200 ]; then
  pass "a pod cannot reach the metadata address, which the host itself reaches (200)"
else
  pass "a pod cannot reach the metadata address (the host has no metadata service here: ${host_md:-no answer})"
fi
# The host's address on the bridge. Two ways out were open there until
# 2026-10-20 (runs 39371733895 and 39373144875): the host's SSH port, which the
# forwarding rule does not cover (traffic to the host takes INPUT), and port
# 53, which kind's node sends to Docker's embedded DNS, answered by dockerd
# from the host.
gw="$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' | tr ' ' '\n' | grep -m1 -E '^[0-9.]+$')"
open_ports=""
for port in 22 53 80 443 3128 8080; do reach "$gw" "$port" && open_ports="$open_ports $port"; done
if [ -n "$open_ports" ]; then
  fail "a pod opened TCP on the host ($gw):$open_ports"
else
  pass "a pod can open no port on the host ($gw; tried 22 53 80 443 3128 8080)"
fi
# Gated: a resolver on the host that a pod can ask is a way out by DNS, the
# oldest exfiltration channel there is, whatever the forwarding rule says.
if out="$(kubectl exec probe -- nslookup -timeout=3 example.com "$gw" 2>&1)" && grep -qE '^Address: [0-9]' <<<"$(sed -n '/^Name:/,$p' <<<"$out")"; then
  fail "a pod resolved example.com by asking the host itself ($gw): a way out by DNS"
else
  pass "a pod cannot resolve an outside name through the host ($gw)"
fi
if curl -6 -g -s -m 5 -o /dev/null 'https://[2606:4700:4700::1111]/' 2>/dev/null; then
  measured+=("IPv6 route out from the runner: yes (the ip6tables rule is in place; the cluster is IPv4 only)")
else
  measured+=("IPv6 route out from the runner: none (so the ip6tables rule is untested here)")
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
if docker exec "$NODE" curl -sk -m 5 -o /dev/null https://registry.boundary.internal:5000/v2/ 2>/dev/null; then
  pass "control: the node reaches the registry inside over TLS"
else
  fail "control: the node cannot reach the registry inside, so its refusal below proves nothing"
fi
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
tls="$(curl -s -m 5 -o /dev/null -w '%{http_code}' --cacert "$STATE/ca.crt" https://registry.boundary.internal:5000/v2/ || true)"
code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://registry.boundary.internal:5000/v2/ || true)"
if [ "$tls" != 200 ]; then
  fail "control: the registry did not answer over TLS (got ${tls:-no answer}), so a refused plain request proves nothing"
elif [ "$code" = 200 ]; then
  fail "the registry answered plain HTTP with 200"
else
  pass "the registry answers TLS (200) and refuses plain HTTP (got ${code:-no answer})"
fi

step "9. admission refuses model weights it cannot vouch for"
model="$(kubectl -n inference get deployment llama -o jsonpath='{.spec.template.spec.volumes[0].image.reference}')"
for plant in "$ROOT"/tests/e2e/plants/*.yaml; do
  name="$(basename "$plant" .yaml)"
  expect="$(sed -n 's/^# expect: //p' "$plant")"
  out="$(sed -e "s#@BUSYBOX@#$BUSYBOX#g" -e "s#@MODEL@#$model#g" -e "s#@MODEL_TAG@#${model%@*}:q4_k_m#g" \
             -e "s#@UNSIGNED@#$REG/models/plant-unsigned@$(cat "$STATE/plant-unsigned.digest")#g" \
             -e "s#@STRANGER@#$REG/models/plant-stranger@$(cat "$STATE/plant-stranger.digest")#g" \
             -e "s#@UNLICENSED@#$REG/models/plant-unlicensed@$(cat "$STATE/plant-unlicensed.digest")#g" \
             -e "s#@NOBOM@#$REG/models/plant-nobom@$(cat "$STATE/plant-nobom.digest")#g" \
             -e "s#@MIXED@#$REG/models/plant-mixed@$(cat "$STATE/plant-mixed.digest")#g" \
             -e "s#@SECOND@#$REG/models/plant-second@$(cat "$STATE/plant-second.digest")#g" \
             -e "s#@EXPRESSION@#$REG/models/plant-expression@$(cat "$STATE/plant-expression.digest")#g" \
             -e "s#@CONCLUDED@#$REG/models/plant-concluded@$(cat "$STATE/plant-concluded.digest")#g" "$plant" \
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

step "11. nothing that runs came from anywhere else"
# Read back, not assumed: every pod in the namespaces carried-images covers,
# every container image, against the digests the policy was given.
if [ -s "$STATE/carried-digests.txt" ]; then
  stray="$(kubectl get pods -A -o json | jq -r --arg carried "$(cat "$STATE/carried-digests.txt")" '
    ($carried | split(" ")) as $c
    | .items[] | select(.metadata.namespace != "kube-system" and .metadata.namespace != "local-path-storage")
    | . as $p | ([.spec.containers[], (.spec.initContainers // [])[]] | .[].image)
    | select((split("@") | .[1] // "") as $d | ($c | index($d)) == null)
    | "\($p.metadata.namespace)/\($p.metadata.name): \(.)"')"
  running="$(kubectl get pods -A --no-headers 2>/dev/null | awk '$1 != "kube-system" && $1 != "local-path-storage"' | grep -c .)"
  if [ -z "$stray" ] && [ "$running" -gt 0 ]; then
    pass "every pod outside the node image's namespaces runs images the bundle carried ($running pods, $(wc -w <"$STATE/carried-digests.txt" | tr -d ' ') digests)"
  else
    fail "pods run images the bundle did not carry: $(head -c 300 <<<"$stray")"
  fi
else
  fail "no list of the digests the bundle carried: scripts/admission.sh policy writes it"
fi

step "12. only the loader writes to the registry inside"
# After 10 and 11, which count what the registry holds. A write here starts
# an upload and goes no further: the control's upload is cancelled, which
# leaves the name in zot's catalog with no tag, and check 10 counts tags. The
# password reaches curl on its stdin, never as an argument.
up="https://$REG/v2/boundary-write-probe/blobs/uploads/"
anon="$(curl -s -m 5 -o /dev/null -w '%{http_code}' --cacert "$STATE/ca.crt" -X POST "$up" || true)"
wrong="$(printf 'user = "loader:not-the-password"\n' | curl -s -m 5 -o /dev/null -w '%{http_code}' --cacert "$STATE/ca.crt" -K - -X POST "$up" || true)"
loader() { { printf 'user = "loader:'; tr -d '\n' <"$STATE/registry.password"; printf '"\n'; } | curl -s -m 5 --cacert "$STATE/ca.crt" -K - "$@"; }
headers="$(loader -o /dev/null -D - -X POST "$up" || true)"
code="$(awk 'NR == 1 {print $2}' <<<"$headers")"
location="$(awk -F': ' 'tolower($1) == "location" {print $2}' <<<"$headers" | tr -d '\r')"
if [ "$code" != 202 ]; then
  fail "control: with the loader's password a push did not start (HTTP ${code:-no answer}), so the refusals below prove nothing"
else
  pass "control: with the loader's password, a push starts (HTTP 202); cancelled: HTTP $(loader -o /dev/null -w '%{http_code}' -X DELETE "https://$REG$location" || true)"
fi
if [ "$anon" = 401 ] && [ "$wrong" = 401 ]; then
  pass "the registry inside refuses a push with no password (HTTP $anon) and with a wrong one (HTTP $wrong)"
else
  fail "the registry inside answered a push with no password HTTP ${anon:-none}, with a wrong one HTTP ${wrong:-none}: anything that reaches it can write"
fi

kubectl delete pod probe --wait=false >/dev/null 2>&1
printf '\n'; printf '%s\n' "${results[@]}"
[ "${#measured[@]}" -gt 0 ] && printf '  measured  %s\n' "${measured[@]}"
if [ -n "${E2E_RESULTS:-}" ]; then
  { printf '%s\n' "${results[@]}"; printf '\n--measured--\n'; printf '%s\n' "${measured[@]}"; } | python3 -c '
import json, sys
lines = sys.stdin.read().split("\n--measured--\n")
checks = [{"name": l[6:].strip(), "passed": l.startswith("PASS")} for l in lines[0].splitlines() if l.strip()]
measured = [l for l in (lines[1] if len(lines) > 1 else "").splitlines() if l.strip()]
json.dump({"checks": checks, "measured": measured}, open(sys.argv[1], "w"), indent=1)' "$E2E_RESULTS"
fi
exit "$failed"
