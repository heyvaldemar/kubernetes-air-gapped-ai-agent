#!/usr/bin/env bash
# tests/e2e/gateway.sh - two model servers behind one gateway, inside the
# boundary. From a pod in the agents namespace, which reaches the gateway
# and, once the gateway is installed, nothing that serves a model directly:
#
#   1. a request that names granite-4.0-1b is answered by granite-4.0-1b
#   2. a request that names minicpm5-2b is answered by minicpm5-2b
#   3. a request that names a model with no route is refused at the gateway
#   4. a caller with no token, or with a token for the Kubernetes API rather
#      than the gateway, is refused with 401
#   5. the quota follows the service account: a workload's fourth request in
#      a minute is refused with 429, and writing the agent's name into a
#      header does not lift it; another workload, right after, is still
#      served, and the support agent has its own, larger quota
#   6. the model servers cannot be reached around the gateway
#   7. the token budget follows the service account too: a workload's one
#      long request is served and spends more than its 1,000 tokens, and its
#      next request, its second of the minute, is refused with 429; the
#      support agent's same long request is served
#   8. the proxy's metrics answer, count the refusal, and count each model's
#      tokens
#
# Each answer names the model that produced it: the server reports its
# --alias, so a request routed to the wrong server says so. Tokens are made
# for each request with kubectl create token and reach the client pod on
# stdin, never in an argument. Writes $E2E_RESULTS (JSON) when set.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PY="$(grep -E '^docker.io/library/python:' "$ROOT/airgap/images.txt")"
AUDIENCE=models.boundary.heyvaldemar.com
results=(); failed=0
pass() { results+=("PASS  $1"); printf '  PASS  %s\n' "$1"; }
fail() { results+=("FAIL  $1"); printf '  FAIL  %s\n' "$1"; failed=1; }

svc="$(kubectl -n gateway get svc -o jsonpath='{.items[0].metadata.name}')"
GW="http://$svc.gateway.svc.cluster.local:8080"

# Four workloads besides the agent: one for the routes, two for the quota,
# one for the token budget.
for sa in gw-routes gw-busy gw-other gw-tokens; do
  kubectl -n agents create serviceaccount "$sa" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done
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

# token <who>: a token for the gateway's audience as service account <who>
# in agents; api:<who> is one for the Kubernetes API's audience instead, and
# none is no token at all.
token() {
  case "$1" in
    none) printf '' ;;
    api:*) kubectl -n agents create token "${1#api:}" --duration 10m ;;
    *) kubectl -n agents create token "$1" --audience "$AUDIENCE" --duration 10m ;;
  esac
}

# ask <model> <who> [claim] [words]: "<status> <model that answered>". With a
# claim, the request also says x-client-id: <claim>, as a caller may write
# anything. With words, the prompt carries that many more words, about a
# token each, for the token budget.
ask() {
  token "$2" | kubectl -n agents exec -i gw-client -- python3 -c '
import json, sys, urllib.request, urllib.error
url, model, claim, words = sys.argv[1:5]
headers = {"Content-Type": "application/json"}
tok = sys.stdin.read().strip()
if tok:
    headers["Authorization"] = "Bearer " + tok
if claim:
    headers["x-client-id"] = claim
body = json.dumps({"model": model, "max_tokens": 1,
                   "messages": [{"role": "user", "content": "Say OK." + " word" * int(words)}]}).encode()
req = urllib.request.Request(url + "/v1/chat/completions", data=body, method="POST", headers=headers)
try:
    with urllib.request.urlopen(req, timeout=180) as r:
        print(r.status, json.loads(r.read()).get("model", "?"))
except urllib.error.HTTPError as e:
    print(e.code, "-")
except Exception as e:
    print(0, type(e).__name__)
' "$GW" "$1" "${3:-}" "${4:-0}" 2>/dev/null || echo "0 exec-failed"
}

printf '\n== 1-2. each model by name\n'
for m in granite-4.0-1b minicpm5-2b; do
  read -r code who <<<"$(ask "$m" gw-routes)"
  if [ "$code" = 200 ] && [ "$who" = "$m" ]; then pass "a request for $m is answered by $m"
  else fail "a request for $m: HTTP $code, answered by '$who'"; fi
done

printf '\n== 3. a model with no route\n'
read -r code who <<<"$(ask gpt-5 gw-routes)"
if [ "$code" = 404 ]; then pass "a request for a model with no route is refused at the gateway (404)"
else fail "a request for a model with no route: HTTP $code, answered by '$who'"; fi

printf '\n== 4. who is calling\n'
read -r code _ <<<"$(ask granite-4.0-1b none)"
if [ "$code" = 401 ]; then pass "a request with no token is refused (401)"
else fail "a request with no token: HTTP $code, expected 401"; fi
read -r code _ <<<"$(ask granite-4.0-1b api:gw-other)"
if [ "$code" = 401 ]; then pass "a token for the Kubernetes API, not for the gateway, is refused (401)"
else fail "a token for the Kubernetes API's audience: HTTP $code, expected 401"; fi

printf '\n== 5. a quota per service account\n'
codes=""
for _ in 1 2 3 4; do read -r code _ <<<"$(ask granite-4.0-1b gw-busy)"; codes="$codes $code"; done
if [ "$codes" = " 200 200 200 429" ]; then pass "a workload's fourth request in a minute is refused with 429 (got$codes)"
else fail "a workload's four requests in a minute: got$codes, expected 200 200 200 429"; fi
read -r code _ <<<"$(ask granite-4.0-1b gw-busy support-agent)"
if [ "$code" = 429 ]; then pass "writing x-client-id: support-agent does not lift its quota (429)"
else fail "a workload claiming the agent's name in a header: HTTP $code, expected 429"; fi
read -r code _ <<<"$(ask granite-4.0-1b gw-other)"
if [ "$code" = 200 ]; then pass "another workload, right after, is still served"
else fail "another workload, right after: HTTP $code"; fi
codes=""
for _ in 1 2 3 4; do read -r code _ <<<"$(ask granite-4.0-1b support-agent)"; codes="$codes $code"; done
if [ "$codes" = " 200 200 200 200" ]; then pass "the support agent has its own, larger quota: four in a row served (got$codes)"
else fail "the support agent's four requests in a minute: got$codes, expected 200 200 200 200"; fi

printf '\n== 6. no way around the gateway\n'
direct="$(kubectl -n agents exec gw-client -- python3 -c '
import urllib.request
try:
    urllib.request.urlopen("http://granite.inference.svc.cluster.local:8080/health", timeout=8); print("reached")
except Exception as e:
    print("blocked", type(e).__name__)
' 2>/dev/null)"
if [[ "$direct" == blocked* ]]; then pass "the model servers cannot be reached around the gateway ($direct)"
else fail "a model server answered directly, around the gateway: $direct"; fi

printf '\n== 7. a token budget per service account\n'
# 1,500 words is about 1,500 tokens, more than the 1,000 a minute any
# workload but the agent may spend. The budget is settled when the answer is
# complete, so the long request is served and the next one is refused; that
# next one is only the workload's second request this minute, under its
# request quota of 3, so the refusal is the token budget's.
read -r code _ <<<"$(ask granite-4.0-1b gw-tokens "" 1500)"
read -r code2 _ <<<"$(ask granite-4.0-1b gw-tokens)"
if [ "$code $code2" = "200 429" ]; then pass "a workload that spent its 1,000 tokens in one request is refused the next (429), its second request of the minute"
else fail "a workload's long request, then a short one: got $code $code2, expected 200 429 (a token budget the gateway never charges refuses nothing)"; fi
read -r code _ <<<"$(ask granite-4.0-1b support-agent "" 1500)"
if [ "$code" = 200 ]; then pass "the support agent's same long request is served, within its own 60,000 tokens"
else fail "the support agent's long request: HTTP $code, expected 200"; fi

printf '\n== 8. the proxy counts what it did\n'
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
# The tokens it counted, per model, input and output: the series the token
# budget is charged from (the cached part of the input is reported apart, and
# is already in the input). None for a model means the gateway never read its
# answers.
for m in granite-4.0-1b minicpm5-2b; do
  n="$(grep -E '^agentgateway_gen_ai_client_token_usage_sum\{' <<<"$metrics" | grep "gen_ai_request_model=\"$m\"" \
       | grep -E 'gen_ai_token_type="(input|output)"' \
       | awk '{s += $NF} END {printf "%d", s}')"
  if [ "${n:-0}" -gt 0 ]; then pass "the proxy counted $n tokens in $m's requests and answers"
  else fail "the proxy counted no tokens for $m: it never read that model's answers"; fi
done

kubectl -n agents delete pod gw-client --wait=false >/dev/null 2>&1
kubectl -n agents delete serviceaccount gw-routes gw-busy gw-other gw-tokens --ignore-not-found >/dev/null 2>&1
printf '\n'; printf '%s\n' "${results[@]}"
if [ -n "${E2E_RESULTS:-}" ]; then
  printf '%s\n' "${results[@]}" | python3 -c '
import json, sys
checks = [{"name": l[6:].strip(), "passed": l.startswith("PASS")} for l in sys.stdin if l.strip()]
json.dump({"checks": checks, "measured": []}, open(sys.argv[1], "w"), indent=1)' "$E2E_RESULTS"
fi
exit "$failed"
