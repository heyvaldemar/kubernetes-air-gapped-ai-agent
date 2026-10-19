#!/usr/bin/env bash
# tests/e2e/gateway.sh - two model servers behind one gateway, inside the
# boundary. From a pod in the agents namespace, which reaches the gateway
# and, once the gateway is installed, nothing that serves a model directly:
#
#   1. a request that names granite-4.0-1b is answered by granite-4.0-1b
#   2. a request that names minicpm5-2b is answered by minicpm5-2b
#   3. a request that names a model with no route is refused at the gateway
#   4. a client gets three requests a minute: the fourth is refused with 429,
#      and another client, sent right after, is still served
#   5. the model servers cannot be reached around the gateway
#   6. the proxy's metrics answer, and count the refusal
#
# Each answer names the model that produced it: the server reports its
# --alias, so a request routed to the wrong server says so. Writes
# $E2E_RESULTS (JSON) when set.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PY="$(grep -E '^docker.io/library/python:' "$ROOT/airgap/images.txt")"
results=(); failed=0
pass() { results+=("PASS  $1"); printf '  PASS  %s\n' "$1"; }
fail() { results+=("FAIL  $1"); printf '  FAIL  %s\n' "$1"; failed=1; }

svc="$(kubectl -n gateway get svc -o jsonpath='{.items[0].metadata.name}')"
GW="http://$svc.gateway.svc.cluster.local:8080"

kubectl -n agents delete pod gw-client --ignore-not-found --wait=true >/dev/null 2>&1
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: gw-client, namespace: agents}
spec:
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: c
      image: $PY
      command: [sleep, "3600"]
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
EOF
kubectl -n agents wait pod/gw-client --for=condition=Ready --timeout=120s >/dev/null

# ask <model> <client>: "<status> <model that answered>"
ask() {
  kubectl -n agents exec gw-client -- python3 -c '
import json, sys, urllib.request, urllib.error
url, model, client = sys.argv[1:4]
body = json.dumps({"model": model, "max_tokens": 1,
                   "messages": [{"role": "user", "content": "Say OK."}]}).encode()
req = urllib.request.Request(url + "/v1/chat/completions", data=body, method="POST",
                             headers={"Content-Type": "application/json", "x-client-id": client})
try:
    with urllib.request.urlopen(req, timeout=180) as r:
        print(r.status, json.loads(r.read()).get("model", "?"))
except urllib.error.HTTPError as e:
    print(e.code, "-")
except Exception as e:
    print(0, type(e).__name__)
' "$GW" "$1" "$2" 2>/dev/null || echo "0 exec-failed"
}

printf '\n== 1-2. each model by name\n'
for m in granite-4.0-1b minicpm5-2b; do
  read -r code who <<<"$(ask "$m" "first-$m")"
  if [ "$code" = 200 ] && [ "$who" = "$m" ]; then pass "a request for $m is answered by $m"
  else fail "a request for $m: HTTP $code, answered by '$who'"; fi
done

printf '\n== 3. a model with no route\n'
read -r code who <<<"$(ask gpt-5 unknown-model)"
if [ "$code" = 404 ]; then pass "a request for a model with no route is refused at the gateway (404)"
else fail "a request for a model with no route: HTTP $code, answered by '$who'"; fi

printf '\n== 4. three requests a minute per client\n'
codes=""
for _ in 1 2 3 4; do read -r code _ <<<"$(ask granite-4.0-1b noisy)"; codes="$codes $code"; done
read -r quiet _ <<<"$(ask granite-4.0-1b quiet)"
if [ "$codes" = " 200 200 200 429" ]; then pass "a client's fourth request in a minute is refused with 429 (got$codes)"
else fail "a client's four requests in a minute: got$codes, expected 200 200 200 429"; fi
if [ "$quiet" = 200 ]; then pass "another client, right after, is still served"
else fail "another client, right after: HTTP $quiet"; fi

printf '\n== 5. no way around the gateway\n'
direct="$(kubectl -n agents exec gw-client -- python3 -c '
import urllib.request
try:
    urllib.request.urlopen("http://granite.inference.svc.cluster.local:8080/health", timeout=8); print("reached")
except Exception as e:
    print("blocked", type(e).__name__)
' 2>/dev/null)"
if [[ "$direct" == blocked* ]]; then pass "the model servers cannot be reached around the gateway ($direct)"
else fail "a model server answered directly, around the gateway: $direct"; fi

printf '\n== 6. the proxy counts what it did\n'
pod_ip="$(kubectl -n gateway get pod -o jsonpath='{.items[0].status.podIP}')"
metrics="$(kubectl -n agents exec gw-client -- python3 -c '
import sys, urllib.request
print(urllib.request.urlopen("http://%s:15020/metrics" % sys.argv[1], timeout=10).read().decode())
' "$pod_ip" 2>/dev/null)"
# A request counter labelled with the 429 and its reason, the rate limit,
# not the string 429 anywhere: a byte count or a bucket could carry those
# digits and prove nothing.
refused="$(grep -E '^agentgateway_requests_total\{' <<<"$metrics" | grep 'status="429"' | grep 'reason="RateLimit"' | head -1)"
if [ -n "$refused" ]; then pass "the proxy's request counter records the 429: ${refused:0:160}"
else fail "the proxy's request counter has no series for a 429"; fi
grep -E '^agentgateway_requests_total\{' <<<"$metrics" | head -8 | cut -c1-200 | sed 's/^/   series: /'

kubectl -n agents delete pod gw-client --wait=false >/dev/null 2>&1
printf '\n'; printf '%s\n' "${results[@]}"
if [ -n "${E2E_RESULTS:-}" ]; then
  printf '%s\n' "${results[@]}" | python3 -c '
import json, sys
checks = [{"name": l[6:].strip(), "passed": l.startswith("PASS")} for l in sys.stdin if l.strip()]
json.dump({"checks": checks, "measured": []}, open(sys.argv[1], "w"), indent=1)' "$E2E_RESULTS"
fi
exit "$failed"
