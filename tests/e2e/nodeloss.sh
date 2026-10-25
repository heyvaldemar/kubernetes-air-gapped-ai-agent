#!/usr/bin/env bash
# tests/e2e/nodeloss.sh - a node lost while the boundary serves (ADR 20). On
# a cluster with two workers, where the model server, the gateway's proxy and
# Kyverno's admission controller each run two replicas, one on each worker,
# with disruption budgets, and the agent's calls go through the gateway:
#
#   1. a worker lost the way a crash loses it: on kind its container killed,
#      on AWS its instance terminated. A request through the gateway every
#      0.75 s from a client on the other worker, each given 10 s, and every
#      two seconds a pod that mounts a model nobody signed and one that
#      mounts the signed model, tried at admission. The model nobody signed
#      must be refused every time: a lost admission replica is an outage,
#      never a hole. Then how many requests went unanswered, for how long,
#      and whether the gateway and admission were back before the window
#      closed
#   2. the node back: on kind the same container started again, on AWS the
#      instance the node group launches in its place. Then the boundary,
#      tried from a pod on that node with the node's own resolver: a node
#      that comes back must come back closed. And the replicas spread over
#      both nodes again
#   3. a worker drained, the way maintenance and upgrades take a node: under
#      the same traffic and the same admission probes, every request must be
#      answered and admission must never stop, which is what the budgets and
#      the second replicas are for
#
# NODE_LOSS=kind (default) or aws. Appends its checks to $E2E_RESULTS (JSON)
# when set; the lines marked MEASURED are the numbers. The images and the
# models come from the registry inside (scripts/inside.sh).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE="$ROOT/.cache/airgap"
# shellcheck source=scripts/inside.sh
. "$ROOT/scripts/inside.sh"
MODE="${NODE_LOSS:-kind}"
BUSYBOX="$(relocated "$(grep -E '^docker.io/library/busybox:' "$ROOT/airgap/images.txt")")"
PY="$(relocated "$(grep -E '^docker.io/library/python:' "$ROOT/airgap/images.txt")")"
AUDIENCE=models.boundary.heyvaldemar.com
SERVED="${SERVED_DEPLOYMENT:-llama}"
MODEL_NAME="${SERVED_MODEL:-granite-4.0-1b}"
results=(); measured=(); failed=0
pass() { results+=("PASS  $1"); printf '  PASS  %s\n' "$1"; }
fail() { results+=("FAIL  $1"); printf '  FAIL  %s\n' "$1"; failed=1; }
measure() { measured+=("$1"); printf '  MEASURED  %s\n' "$1"; }
step() { printf '\n== %s\n' "$*"; }
record() {
  printf '\n'; printf '%s\n' "${results[@]}"; [ "${#measured[@]}" -eq 0 ] || printf 'MEASURED  %s\n' "${measured[@]}"
  [ -n "${E2E_RESULTS:-}" ] || return 0
  { printf '%s\n' "${results[@]}"; printf '\n--measured--\n'; [ "${#measured[@]}" -eq 0 ] || printf '%s\n' "${measured[@]}"; } | python3 -c '
import json, os, sys
out = sys.argv[1]
lines = sys.stdin.read().split("\n--measured--\n")
d = json.load(open(out)) if os.path.exists(out) else {"checks": [], "measured": []}
d["checks"] += [{"name": l[6:].strip(), "passed": l.startswith("PASS")} for l in lines[0].splitlines() if l.strip()]
d.setdefault("measured", []).extend(l for l in (lines[1] if len(lines) > 1 else "").splitlines() if l.strip())
json.dump(d, open(out, "w"), indent=1)' "$E2E_RESULTS"
}

served="$(kubectl -n inference get deployment "$SERVED" -o jsonpath='{.spec.template.spec.volumes[0].image.reference}')"
unsigned="$MODELS/plant-unsigned@$(cat "$STATE/plant-unsigned.digest")"
svc="$(kubectl -n gateway get svc -o jsonpath='{.items[0].metadata.name}')"
GW="http://$svc.gateway.svc.cluster.local:8080"
LLAMA="app=llama,server=$SERVED"
PROXY=gateway.networking.k8s.io/gateway-name=models
CONTROLLER=app.kubernetes.io/name=agentgateway
KYVERNO=app.kubernetes.io/component=admission-controller

# admitted <ref>: whether the API server admits a pod that mounts this model
# (a server-side dry run: nothing is created), as in gameday.sh.
admitted() {
  kubectl apply --dry-run=server -f - >/dev/null 2>&1 <<EOF
{"apiVersion":"v1","kind":"Pod","metadata":{"name":"nodeloss-probe","namespace":"inference"},"spec":{
 "automountServiceAccountToken":false,
 "securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}},
 "containers":[{"name":"c","image":"$BUSYBOX","command":["sleep","3600"],
  "securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}},
  "volumeMounts":[{"name":"model","mountPath":"/models","readOnly":true}]}],
 "volumes":[{"name":"model","image":{"reference":"$1","pullPolicy":"IfNotPresent"}}]}}
EOF
}

# watch_admission <seconds>: every two seconds, the model nobody signed and
# the signed one at admission. Prints "<tries> <unsigned admitted> <signed
# refused> <first refusal, s> <last refusal, s>", seconds from the start.
watch_admission() {
  local t0=$SECONDS tries=0 holes=0 refused=0 first="" last=""
  while [ $((SECONDS - t0)) -lt "$1" ]; do
    tries=$((tries + 1))
    admitted "$unsigned" && holes=$((holes + 1))
    if ! admitted "$served"; then
      refused=$((refused + 1)); [ -n "$first" ] || first=$((SECONDS - t0)); last=$((SECONDS - t0))
    fi
    sleep 2
  done
  echo "$tries $holes $refused ${first:--} ${last:--}"
}

# watch_calls <seconds>: from the client, one short request through the
# gateway every 0.75 s, inside the agent's quota of 100 a minute, made the way
# the agent makes them (evals/harness.py, ADR 20): two seconds to connect, ten
# for the answer, and a call that never connected asked again, up to five
# times. Prints "<sent> <answered> <not answered> <longest gap, s> <first
# failure, s> <last failure, s> <the last 20 all answered: yes|no> <asked
# again> <codes>".
watch_calls() {
  kubectl -n agents create token support-agent --audience "$AUDIENCE" --duration 15m \
    | kubectl -n agents exec -i nodeloss-client -- python3 -c '
import collections, http.client, json, socket, sys, time, urllib.parse
url, model, secs = sys.argv[1], sys.argv[2], float(sys.argv[3])
u = urllib.parse.urlsplit(url)
tok = sys.stdin.read().strip()
body = json.dumps({"model": model, "max_tokens": 1, "messages": [{"role": "user", "content": "Say OK."}]})
headers = {"Content-Type": "application/json", "Authorization": "Bearer " + tok}
def call():
    again = 0
    for _ in range(5):
        try:
            sock = socket.create_connection((u.hostname, u.port), 2)
        except OSError:
            again += 1
            continue
        conn = http.client.HTTPConnection(u.hostname, u.port, timeout=10)
        conn.sock = sock
        sock.settimeout(10)
        try:
            conn.request("POST", "/v1/chat/completions", body, headers)
            r = conn.getresponse()
            r.read()
            return r.status, again
        except Exception:
            return 0, again
        finally:
            conn.close()
    return 0, again
codes, recent = collections.Counter(), collections.deque(maxlen=20)
start = last = time.monotonic()
gap, first_fail, last_fail, asked_again = 0.0, None, None, 0
while time.monotonic() - start < secs:
    t = time.monotonic()
    code, again = call()
    asked_again += again
    codes[code] += 1
    recent.append(code)
    now = time.monotonic()
    if code == 200:
        gap, last = max(gap, now - last), now
    else:
        first_fail = first_fail if first_fail is not None else t - start
        last_fail = t - start
    time.sleep(max(0.0, 0.75 - (now - t)))
gap = max(gap, time.monotonic() - last)
sent = sum(codes.values())
f = lambda x: "-" if x is None else str(round(x, 1))
print(sent, codes[200], sent - codes[200], round(gap, 1), f(first_fail), f(last_fail),
      "yes" if len(recent) == 20 and all(c == 200 for c in recent) else "no", asked_again,
      ",".join("%s:%d" % kv for kv in sorted(codes.items())))
' "$GW" "$MODEL_NAME" "$1" 2>/dev/null || echo "0 0 0 0 - - no 0 exec-failed"
}

# on_nodes <ns> <selector>: the nodes the ready pods run on, one a line.
on_nodes() {
  kubectl -n "$1" get pods -l "$2" -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    | awk '$2 == "True" {print $1}' | sort -u
}
spread() {  # spread <ns> <selector> <what>
  local nodes; nodes="$(on_nodes "$1" "$2" | paste -sd, -)"
  if [ "$(tr ',' '\n' <<<"$nodes" | grep -c .)" -ge 2 ]; then pass "$3: ready on two nodes ($nodes)"
  else fail "$3: ready on '${nodes:-no node}' only"; fi
}
# respread <ns> <selector> <what>: when both replicas share a node, the
# newer one goes and comes back where there is room, on the other node.
respread() {
  if [ "$(on_nodes "$1" "$2" | grep -c .)" -lt 2 ]; then
    kubectl -n "$1" delete pod "$(kubectl -n "$1" get pods -l "$2" --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')" --wait=false >/dev/null 2>&1
    for _ in $(seq 1 90); do [ "$(on_nodes "$1" "$2" | grep -c .)" -ge 2 ] && break; sleep 4; done
  fi
  spread "$@"
}
budget() {  # budget <ns> <selector> <what>: a budget that lets one go, and no more
  local b
  b="$(kubectl -n "$1" get pdb -o json | python3 -c '
import json, sys
sel = dict(kv.split("=", 1) for kv in sys.argv[1].split(","))
for p in json.load(sys.stdin)["items"]:
    if all(p["spec"].get("selector", {}).get("matchLabels", {}).get(k) == v for k, v in sel.items()):
        s = p.get("status", {})
        print(p["metadata"]["name"], s.get("currentHealthy", 0), s.get("disruptionsAllowed", 0)); break' "$2")"
  read -r name healthy allowed <<<"$b"
  if [ -n "$name" ] && [ "$healthy" -ge 2 ] && [ "$allowed" = 1 ]; then pass "$3: disruption budget $name lets one of $healthy go at a time"
  else fail "$3: no disruption budget lets exactly one go (${b:-none})"; fi
}
ready_status() { kubectl get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null; }
seconds_until() {  # seconds_until <limit> <command...>
  local t0=$SECONDS limit="$1"; shift
  while [ $((SECONDS - t0)) -lt "$limit" ]; do
    if "$@" >/dev/null 2>&1; then echo $((SECONDS - t0)); return 0; fi
    sleep 2
  done
  return 1
}
# shellcheck disable=SC2329 # called through seconds_until
not_ready() { [ "$(ready_status "$1")" != True ]; }
is_ready() { [ "$(ready_status "$1")" = True ]; }

lose() {
  case "$MODE" in
    kind) docker kill "$1" >/dev/null ;;
    aws)
      local id; id="$(kubectl get node "$1" -o jsonpath='{.spec.providerID}')"
      aws ec2 terminate-instances --instance-ids "${id##*/}" >/dev/null ;;
  esac
}
# back <lost node>: prints the node that takes its place, once Ready.
back() {
  case "$MODE" in
    kind)
      docker start "$1" >/dev/null
      seconds_until 300 is_ready "$1" >/dev/null && echo "$1" ;;
    aws)
      local t0=$SECONDS n
      while [ $((SECONDS - t0)) -lt 900 ]; do
        for n in $(kubectl get nodes -l '!boundary.heyvaldemar.com/accelerator' -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
          [ "$n" = "$1" ] || [ "$n" = "$survivor" ] && continue
          is_ready "$n" && { echo "$n"; return 0; }
        done
        sleep 10
      done ;;
  esac
}

# The pod on a node, for the boundary probes there: the node's own resolver
# (dnsPolicy Default), as a pod a workload's author chose could use. In the
# default namespace, as run.sh's probe: the agents' own network policies
# would refuse its DNS whatever the node did, and prove nothing about it.
probe_on() {  # probe_on <node>
  kubectl delete pod nodeloss-dns --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: nodeloss-dns, namespace: default}
spec:
  automountServiceAccountToken: false
  nodeSelector: {kubernetes.io/hostname: $1}
  dnsPolicy: Default
  securityContext: {runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: c
      image: $BUSYBOX
      command: [sleep, "3600"]
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
EOF
  kubectl wait pod/nodeloss-dns --for=condition=Ready --timeout=180s >/dev/null
}
resolves() { out="$(kubectl exec nodeloss-dns -- nslookup -timeout=3 example.com "$@" 2>&1)" && grep -qE '^Address: [0-9]' <<<"$(sed -n '/^Name:/,$p' <<<"$out")"; }

step "0. two of each, on two nodes"
mapfile -t workers < <(kubectl get nodes -l '!node-role.kubernetes.io/control-plane,!boundary.heyvaldemar.com/accelerator' \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)
if [ "${#workers[@]}" -ne 2 ]; then
  fail "the drill needs two workers, and the cluster has ${#workers[@]}: ${workers[*]}"
  record; exit 1
fi
survivor="${workers[0]}" victim="${workers[1]}"
measure "the workers: $survivor stays, $victim is lost ($MODE)"
spread inference "$LLAMA" "the model server"
spread gateway "$PROXY" "the gateway's proxy"
spread agentgateway-system "$CONTROLLER" "the gateway's controller"
spread kyverno "$KYVERNO" "Kyverno's admission controller"
budget inference "$LLAMA" "the model server"
budget gateway "$PROXY" "the gateway's proxy"
budget agentgateway-system "$CONTROLLER" "the gateway's controller"
budget kyverno "$KYVERNO" "Kyverno's admission controller"
measure "CoreDNS runs on: $(on_nodes kube-system k8s-app=kube-dns | paste -sd, -)"

kubectl -n agents delete pod nodeloss-client --ignore-not-found --wait=true >/dev/null 2>&1
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: nodeloss-client, namespace: agents}
spec:
  automountServiceAccountToken: false
  nodeSelector: {kubernetes.io/hostname: $survivor}
  securityContext: {runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: c
      image: $PY
      command: [sleep, "3600"]
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
EOF
kubectl -n agents wait pod/nodeloss-client --for=condition=Ready --timeout=120s >/dev/null
read -r _ answered _ <<<"$(watch_calls 5)"
if [ "${answered:-0}" -gt 0 ]; then pass "control: the gateway answers the client on $survivor"; else fail "control: the gateway does not answer before anything is lost"; fi
if admitted "$served" && ! admitted "$unsigned"; then pass "control: admission admits the signed model and refuses the one nobody signed"
else fail "control: admission is not what it should be before anything is lost"; fi

step "1. a worker lost, the way a crash loses it"
calls="$(mktemp)" adm="$(mktemp)"
watch_calls 240 >"$calls" & wc=$!
watch_admission 240 >"$adm" & wa=$!
sleep 10
lose "$victim"; t_lost=$SECONDS
if s="$(seconds_until 180 not_ready "$victim")"; then measure "the API server saw $victim not ready ${s}s after it was lost"
else measure "the API server still called $victim ready three minutes after it was lost"; fi
wait "$wc" "$wa"
read -r sent answered missed gap first_fail last_fail settled again codes <"$calls"
read -r tries holes refused first_ref last_ref <"$adm"
rm -f "$calls" "$adm"
if [ "${tries:-0}" -gt 0 ] && [ "$holes" = 0 ]; then
  pass "while a node was lost, a model nobody signed was refused every time it was tried ($tries tries)"
else
  fail "while a node was lost, a model nobody signed was admitted $holes time(s) of ${tries:-0}"
fi
measure "the signed model was refused at admission $refused time(s) of $tries while the node was lost (first at ${first_ref}s, last at ${last_ref}s of the window; the loss at 10s)"
if admitted "$served"; then pass "admission admits the signed model again with one replica left"; else fail "admission still refuses the signed model with one replica left"; fi
measure "through the gateway while the node was lost: $answered of $sent answered, $missed not ($codes), the longest wait between two answers ${gap}s, failures from ${first_fail}s to ${last_fail}s of the window (the loss at 10s); $again call(s) asked again after a connection that was never made"
if [ "$settled" = yes ]; then pass "the gateway answers again with one replica of each left: the last 20 requests of the four minutes all answered"
else fail "the gateway does not answer steadily four minutes after the node was lost ($codes)"; fi

step "2. the node back"
t_back=$SECONDS
if newnode="$(back "$victim")" && [ -n "$newnode" ]; then
  pass "a worker is back and ready ($newnode), $((SECONDS - t_back))s after it was asked for, $((SECONDS - t_lost))s after the loss"
  probe_on "$newnode"
  if resolves; then fail "a pod on the node that came back resolved example.com with the node's own resolver: the node came back open"
  else pass "a pod on the node that came back cannot resolve example.com with the node's own resolver"; fi
  if kubectl exec nodeloss-dns -- nc -w 5 1.1.1.1 443 </dev/null >/dev/null 2>&1; then fail "a pod on the node that came back opened TCP to 1.1.1.1:443"
  else pass "a pod on the node that came back cannot open TCP to 1.1.1.1:443"; fi
  if [ "$MODE" = kind ]; then
    gw="$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' | tr ' ' '\n' | grep -m1 -E '^[0-9.]+$')"
    if resolves "$gw"; then fail "a pod on the node that came back resolved example.com through the host ($gw), Docker's DNS"
    else pass "a pod on the node that came back cannot resolve example.com through the host ($gw)"; fi
    if docker exec "$newnode" getent hosts example.com >/dev/null 2>&1; then fail "the node that came back resolves example.com itself"
    else pass "the node that came back cannot resolve example.com itself"; fi
  fi
  # A pod no controller owns stops a drain; it goes first, and for good.
  kubectl delete pod nodeloss-dns --ignore-not-found --wait=true >/dev/null 2>&1
else
  fail "no worker took $victim's place within the limit"
  newnode=""
fi
respread inference "$LLAMA" "the model server, again"
respread gateway "$PROXY" "the gateway's proxy, again"
respread agentgateway-system "$CONTROLLER" "the gateway's controller, again"
respread kyverno "$KYVERNO" "Kyverno's admission controller, again"

step "3. a worker drained, the way maintenance takes it"
if [ -n "$newnode" ]; then
  calls="$(mktemp)" adm="$(mktemp)" drain="$(mktemp)"
  watch_calls 240 >"$calls" & wc=$!
  watch_admission 240 >"$adm" & wa=$!
  sleep 10
  t0=$SECONDS
  if kubectl drain "$newnode" --ignore-daemonsets --delete-emptydir-data --timeout=220s >"$drain" 2>&1; then
    measure "$newnode drained in $((SECONDS - t0))s"
  else
    fail "$newnode did not drain within 220s: $(tail -3 "$drain" | tr '\n' ' ' | head -c 300)"
  fi
  rm -f "$drain"
  wait "$wc" "$wa"
  kubectl uncordon "$newnode" >/dev/null 2>&1
  read -r sent answered missed gap _ _ _ _ codes <"$calls"
  read -r tries holes refused _ _ <"$adm"
  rm -f "$calls" "$adm"
  if [ "${sent:-0}" -gt 0 ] && [ "$missed" = 0 ]; then pass "a node drained under traffic: $answered of $sent requests answered, the longest wait between two answers ${gap}s"
  else fail "a node drained under traffic: $missed of $sent requests not answered ($codes), the longest wait ${gap}s"; fi
  if [ "${tries:-0}" -gt 0 ] && [ "$holes" = 0 ] && [ "$refused" = 0 ]; then pass "admission never stopped while the node drained: the signed model admitted and the one nobody signed refused, $tries times each"
  else fail "admission while the node drained: the signed model refused $refused time(s), the one nobody signed admitted $holes time(s), of ${tries:-0}"; fi
fi

kubectl -n agents delete pod nodeloss-client --ignore-not-found --wait=false >/dev/null 2>&1
record
exit "$failed"
