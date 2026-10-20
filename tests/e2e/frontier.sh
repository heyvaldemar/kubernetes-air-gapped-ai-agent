#!/usr/bin/env bash
# tests/e2e/frontier.sh - prove the one way out (ADR 14), on a cluster made
# from kind/frontier.yaml, closed by scripts/airgap.sh and opened by
# scripts/frontier.sh open. Each check states what it proves.
#
#   1. the gateway's proxy runs on the egress node, and nothing else does but
#      the node's own network agents
#   2. the API server refuses a pod outside the gateway's namespace that
#      tolerates the egress node's taint, tolerates every taint, or names the
#      node; it admits the same pod without them (the control)
#   3. a pod on the other node reaches no Anthropic address, though it
#      reaches the registry inside: the hole is the egress node's alone
#   4. on the egress node, the API's range answers on 443 (the control for
#      3) and nothing else outside does: not another address, not another
#      port of the API's own, not DNS, and no outside name resolves
#
# The model's answers, through that one way, are judged by scripts/evals.sh.
# Writes $E2E_RESULTS (one JSON document) when set.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUSYBOX="$(grep -E '^docker.io/library/busybox:' "$ROOT/airgap/images.txt")"
EGRESS_LABEL=boundary.heyvaldemar.com/egress=anthropic
API_IP="${API_IP:-160.79.104.10}"
results=(); measured=(); failed=0
pass() { results+=("PASS  $1"); printf '  PASS  %s\n' "$1"; }
fail() { results+=("FAIL  $1"); printf '  FAIL  %s\n' "$1"; failed=1; }
step() { printf '\n== %s\n' "$*"; }
egress="$(kubectl get nodes -l "$EGRESS_LABEL" -o jsonpath='{.items[0].metadata.name}')"

step "1. only the gateway runs on the egress node"
# The proxy moved when frontier.sh open placed it; its old pod on the other
# node may still be on its way out.
for _ in $(seq 1 30); do
  gw_nodes="$(kubectl -n gateway get pods -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | tr '\n' ' ' | sed 's/ $//')"
  [ "$gw_nodes" = "$egress" ] && break
  sleep 2
done
others="$(kubectl get pods -A --field-selector "spec.nodeName=$egress" --no-headers 2>/dev/null \
  | awk '$1 != "gateway" && $1 != "kube-system" {print $1 "/" $2}' | tr '\n' ' ')"
agents="$(kubectl -n kube-system get pods --field-selector "spec.nodeName=$egress" --no-headers 2>/dev/null | awk '{print $1}' | sed -E 's/-[a-z0-9]{5}$//' | sort -u | tr '\n' ' ')"
if [ "$gw_nodes" = "$egress" ] && [ -z "$others" ]; then
  pass "the gateway's proxy runs on $egress, and nothing else does but the node's own network agents (${agents% })"
else
  fail "the gateway runs on '${gw_nodes:-nothing}', and on $egress also: ${others:-nothing else}"
fi

step "2. admission decides who may run there"
for plant in "$ROOT"/tests/e2e/plants-frontier/*.yaml; do
  name="$(basename "$plant" .yaml)"
  expect="$(sed -n 's/^# expect: //p' "$plant")"
  out="$(sed -e "s#@BUSYBOX@#$BUSYBOX#g" -e "s#air-gapped-worker#$egress#g" "$plant" | kubectl apply --dry-run=server -f - 2>&1)"; rc=$?
  if [ "$expect" = admitted ]; then
    if [ $rc -eq 0 ]; then pass "$name: admitted (control)"; else fail "$name was refused: $(head -c 300 <<<"$out")"; fi
  elif [ $rc -ne 0 ] && grep -qF "$expect" <<<"$out"; then
    pass "$name: refused ($expect)"
  else
    fail "$name: expected a refusal saying '$expect', got (rc=$rc): $(head -c 300 <<<"$out")"
  fi
done

probe() {  # probe <namespace> <name> [egress]: a busybox pod, restricted, on the egress node if asked
  local where=""
  [ "${3:-}" = egress ] && where=',"nodeSelector":{"boundary.heyvaldemar.com/egress":"anthropic"},"tolerations":[{"key":"boundary.heyvaldemar.com/egress","operator":"Equal","value":"anthropic","effect":"NoSchedule"}]'
  kubectl -n "$1" delete pod "$2" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl -n "$1" apply -f - >/dev/null <<EOF
{"apiVersion":"v1","kind":"Pod","metadata":{"name":"$2","namespace":"$1"},"spec":{
 "automountServiceAccountToken":false,
 "securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}},
 "containers":[{"name":"c","image":"$BUSYBOX","command":["sleep","600"],
  "securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}]$where}}
EOF
  kubectl -n "$1" wait --for=condition=Ready "pod/$2" --timeout=120s >/dev/null 2>&1
}
reach() { kubectl -n "$1" exec "$2" -- nc -w 5 "$3" "$4" </dev/null >/dev/null 2>&1; }

step "3. the other node has no way out, not even this one"
probe default probe-other
if reach default probe-other registry.boundary.internal 5000; then
  pass "control: a pod on the other node opens a connection to the registry inside (TCP 5000)"
else
  fail "control: a pod on the other node reaches nothing inside, so its refusals below prove nothing"
fi
if reach default probe-other "$API_IP" 443; then
  fail "a pod on the other node opened TCP to the API ($API_IP:443): the hole is not the egress node's alone"
else
  pass "a pod on the other node, in a namespace with no network policy, cannot open TCP to the API ($API_IP:443)"
fi
if reach default probe-other 1.1.1.1 443; then fail "a pod on the other node opened TCP to 1.1.1.1:443"; else pass "a pod on the other node cannot open TCP to 1.1.1.1:443"; fi

step "4. from the egress node, the API's range and nothing else"
# In the gateway's namespace, the one admission lets onto the node; deleted
# before the evals, so check 1 holds for them.
probe gateway probe-egress egress
if reach gateway probe-egress "$API_IP" 443; then
  pass "control: from the egress node, the API answers on TCP 443 ($API_IP)"
else
  fail "control: from the egress node, the API does not answer on TCP 443 ($API_IP), so the refusals below prove nothing"
fi
# The API's own address on port 80 answers from outside (checked from a
# connected machine on 2026-10-20), so its refusal here is the firewall's.
for target in 1.1.1.1:443 8.8.8.8:53 140.82.112.3:443 "$API_IP:80"; do
  if reach gateway probe-egress "${target%:*}" "${target#*:}"; then
    fail "from the egress node, a pod opened TCP to $target"
  else
    pass "from the egress node, a pod cannot open TCP to $target"
  fi
done
if out="$(kubectl -n gateway exec probe-egress -- nslookup -timeout=3 api.anthropic.com 2>&1)" && grep -qE '^Address: [0-9]' <<<"$(sed -n '/^Name:/,$p' <<<"$out")"; then
  fail "from the egress node, a pod resolved api.anthropic.com: the boundary answers for an outside name"
else
  pass "from the egress node, a pod resolves no outside name, api.anthropic.com included: the gateway is given the address"
fi
kubectl -n gateway delete pod probe-egress --wait=true >/dev/null 2>&1
kubectl -n default delete pod probe-other --wait=false >/dev/null 2>&1

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
