#!/usr/bin/env bash
# tests/e2e/gameday.sh - take parts of the boundary down while it serves, and
# show which way each one fails. A control that is down is either an outage
# or a hole; this says which, and how long until it is back. Runs after
# tests/e2e/rotation.sh in the gateway job, on a cluster serving
# SERVED_DEPLOYMENT (default granite) behind the gateway, with the plants
# scripts/model.sh plants makes.
#
#   1. the admission controller down. Kyverno verifies the model's signature
#      and reads its AI-BOM in a webhook; the native policies (path, digest,
#      what the bundle carried) need nothing running. With Kyverno at zero
#      replicas: a model nobody signed, and one signed under a licence the
#      site does not allow, are refused (both are in the bundle, so only
#      Kyverno can refuse them); the signed model is refused too, which is
#      the outage, not a hole; the model already served keeps answering.
#      Then Kyverno back, and the seconds until the signed model is admitted
#   2. the gateway's proxy pod killed, with no grace period: the way a node
#      loses it, not the way a rollout replaces it (a graceful delete keeps
#      the old pod serving until the new one is up, and measured nothing the
#      first time this ran). While it is gone the model servers still cannot
#      be reached around it; then how many requests failed and the seconds
#      until the gateway answers again. One replica here, on one kind node:
#      on a real cluster two replicas and a disruption budget are what make
#      this a non-event
#
# Each refusal sits beside a control that must succeed: the served model
# answering, and admission and the gateway coming back. Appends its checks to
# $E2E_RESULTS (JSON) when set; the seconds are in the checks' names, and the
# lines marked MEASURED are for the log.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE="$ROOT/.cache/airgap"
REG=registry.boundary.internal:5000
BUSYBOX="$(grep -E '^docker.io/library/busybox:' "$ROOT/airgap/images.txt")"
PY="$(grep -E '^docker.io/library/python:' "$ROOT/airgap/images.txt")"
AUDIENCE=models.boundary.heyvaldemar.com
SERVED="${SERVED_DEPLOYMENT:-granite}"
MODEL_NAME="${SERVED_MODEL:-granite-4.0-1b}"
results=(); measured=(); failed=0
pass() { results+=("PASS  $1"); printf '  PASS  %s\n' "$1"; }
fail() { results+=("FAIL  $1"); printf '  FAIL  %s\n' "$1"; failed=1; }
measure() { measured+=("$1"); printf '  MEASURED  %s\n' "$1"; }
step() { printf '\n== %s\n' "$*"; }

served="$(kubectl -n inference get deployment "$SERVED" -o jsonpath='{.spec.template.spec.volumes[0].image.reference}')"
unsigned="$REG/models/plant-unsigned@$(cat "$STATE/plant-unsigned.digest")"
unlicensed="$REG/models/plant-unlicensed@$(cat "$STATE/plant-unlicensed.digest")"
svc="$(kubectl -n gateway get svc -o jsonpath='{.items[0].metadata.name}')"
GW="http://$svc.gateway.svc.cluster.local:8080"

# admitted <ref>: whether the API server admits a pod that mounts this model
# (a server-side dry run: nothing is created). The refusal's text is kept in
# $why for the record.
admitted() {
  why="$(kubectl apply --dry-run=server -f - 2>&1 >/dev/null <<EOF
{"apiVersion":"v1","kind":"Pod","metadata":{"name":"gameday-probe","namespace":"inference"},"spec":{
 "automountServiceAccountToken":false,
 "securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}},
 "containers":[{"name":"c","image":"$BUSYBOX","command":["sleep","3600"],
  "securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}},
  "volumeMounts":[{"name":"model","mountPath":"/models","readOnly":true}]}],
 "volumes":[{"name":"model","image":{"reference":"$1","pullPolicy":"IfNotPresent"}}]}}
EOF
)"
}
refused() {  # refused <ref> <what>
  if admitted "$1"; then fail "$2: it was admitted"; else pass "$2 ($(sed -E 's/.*denied the request: //; s/.*(failed calling webhook)/\1/' <<<"$why" | head -c 140))"; fi
}

# A client in the agents namespace, made while everything is up: the
# gateway's caller, and the one place the model servers must stay unreachable
# from.
kubectl -n agents delete pod gameday-client --ignore-not-found --wait=true >/dev/null 2>&1
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: gameday-client, namespace: agents}
spec:
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: c
      image: $PY
      command: [sleep, "3600"]
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
EOF
kubectl -n agents wait pod/gameday-client --for=condition=Ready --timeout=120s >/dev/null

# ask: the HTTP status of one short request through the gateway, 0 when
# nothing answered. As the support agent, whose quota (100 a minute) a probe
# every two seconds stays inside; any other workload gets 3, and a wait for
# the gateway would end up measuring the quota. direct: "reached" or "blocked", straight to the served
# model's server.
ask() {
  kubectl -n agents create token support-agent --audience "$AUDIENCE" --duration 10m \
    | kubectl -n agents exec -i gameday-client -- python3 -c '
import json, sys, urllib.request, urllib.error
url, model = sys.argv[1:3]
tok = sys.stdin.read().strip()
body = json.dumps({"model": model, "max_tokens": 1, "messages": [{"role": "user", "content": "Say OK."}]}).encode()
req = urllib.request.Request(url + "/v1/chat/completions", data=body, method="POST",
                             headers={"Content-Type": "application/json", "Authorization": "Bearer " + tok})
try:
    with urllib.request.urlopen(req, timeout=20) as r:
        print(r.status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print(0)
' "$GW" "$MODEL_NAME" 2>/dev/null || echo 0
}
direct() {
  kubectl -n agents exec gameday-client -- python3 -c '
import urllib.request
try:
    urllib.request.urlopen("http://'"$SERVED"'.inference.svc.cluster.local:8080/health", timeout=8); print("reached")
except Exception:
    print("blocked")
' 2>/dev/null || echo "exec-failed"
}
# seconds_until <command...>: run it every two seconds, up to five minutes,
# until it succeeds; print the seconds it took, or nothing.
seconds_until() {
  local t0=$SECONDS
  for _ in $(seq 1 150); do
    if "$@" >/dev/null 2>&1; then echo $((SECONDS - t0)); return 0; fi
    sleep 2
  done
  return 1
}

step "0. before: the controls"
if admitted "$served"; then pass "control: the signed model is admitted"; else fail "control: the signed model is refused before anything is down: $why"; fi
code="$(ask)"
if [ "$code" = 200 ]; then pass "control: the gateway answers for $MODEL_NAME (200)"; else fail "control: the gateway did not answer before anything is down (HTTP $code)"; fi

step "1. the admission controller down"
hooks_before="$(kubectl get validatingwebhookconfigurations -o name | grep -c kyverno)"
kubectl -n kyverno scale deployment/kyverno-admission-controller --replicas=0 >/dev/null
kubectl -n kyverno wait pod -l app.kubernetes.io/component=admission-controller --for=delete --timeout=180s >/dev/null 2>&1
sleep 15  # what Kyverno does to its own webhooks on the way down, it has done by now
hooks_after="$(kubectl get validatingwebhookconfigurations -o name | grep -c kyverno)"
measure "Kyverno's validating webhook configurations: $hooks_before before its admission controller stopped, $hooks_after after"
refused "$unsigned" "with Kyverno down, a model nobody signed is refused"
refused "$unlicensed" "with Kyverno down, a model signed under a licence the site does not allow is refused"
if admitted "$served"; then fail "with Kyverno down, the signed model was admitted: nothing checked its signature, so the refusals above are luck"
else pass "with Kyverno down, the signed model is refused too: an outage, not a hole"; fi
code="$(ask)"
if [ "$code" = 200 ]; then pass "with Kyverno down, the model already served keeps answering (200)"; else fail "with Kyverno down, the served model stopped answering (HTTP $code)"; fi
kubectl -n kyverno scale deployment/kyverno-admission-controller --replicas=1 >/dev/null
if s="$(seconds_until admitted "$served")"; then
  pass "Kyverno back: the signed model is admitted again, ${s}s after it was scaled up"
else
  fail "Kyverno back: the signed model is still refused five minutes later: $why"
fi
kubectl -n kyverno rollout status deployment/kyverno-admission-controller --timeout=300s >/dev/null 2>&1

step "2. the gateway's proxy pod killed"
pod="$(kubectl -n gateway get pod -o jsonpath='{.items[0].metadata.name}')"
kubectl -n gateway delete pod "$pod" --grace-period=0 --force --wait=false >/dev/null 2>&1
t0=$SECONDS; failed_calls=0; back=""; reach=""
for _ in $(seq 1 150); do
  if [ "$(ask)" = 200 ]; then back=$((SECONDS - t0)); break; fi
  failed_calls=$((failed_calls + 1))
  [ -n "$reach" ] || reach="$(direct)"
  sleep 1
done
[ -n "$reach" ] || reach="$(direct)"
if [ "$reach" = blocked ]; then pass "with the gateway's pod killed, the model server still cannot be reached around it"
else fail "with the gateway's pod killed, the model server answered directly ($reach)"; fi
if [ -n "$back" ]; then
  pass "the gateway answers again, ${back}s after its pod was killed, $failed_calls request(s) failed in between"
else
  fail "the gateway does not answer five minutes after its pod was killed"
fi

kubectl -n agents delete pod gameday-client --ignore-not-found --wait=false >/dev/null 2>&1

printf '\n'; printf '%s\n' "${results[@]}"; printf 'MEASURED  %s\n' "${measured[@]}"
if [ -n "${E2E_RESULTS:-}" ]; then
  printf '%s\n' "${results[@]}" | python3 -c '
import json, os, sys
out = sys.argv[1]
d = json.load(open(out)) if os.path.exists(out) else {"checks": [], "measured": []}
d["checks"] += [{"name": l[6:].strip(), "passed": l.startswith("PASS")} for l in sys.stdin if l.strip()]
json.dump(d, open(out, "w"), indent=1)' "$E2E_RESULTS"
fi
exit "$failed"
