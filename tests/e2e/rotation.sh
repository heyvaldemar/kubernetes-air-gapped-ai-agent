#!/usr/bin/env bash
# tests/e2e/rotation.sh - rotate the operator's signing key with a model
# served, and lose nothing (ADR 16). Runs after scripts/admission.sh policy,
# on a cluster serving SERVED_DEPLOYMENT (default granite) and holding the
# plants scripts/model.sh plants makes.
#
#   1. before: the policy trusts the operator's key. A model signed with the
#      next key alone is refused; one signed with the operator's alone, and
#      the served model, are admitted
#   2. overlap: the policy trusts both. The model signed with the next key is
#      admitted, the others still are; the operator signs the served model
#      and its AI-BOM with the next key, inside the boundary
#   3. after: the policy trusts the next key alone. The model signed with the
#      retired key alone is refused, however recently Kyverno admitted it; the
#      next key's is admitted; the served model, restarted, comes back
#   4. the policy as it was before the drill, for whatever runs after
#
# Each refusal sits beside an admission in the same phase. Appends to
# $E2E_RESULTS (JSON) when set.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE="$ROOT/.cache/airgap"
REG=registry.boundary.internal:5000
export DOCKER_CONFIG="$STATE/docker"
BUSYBOX="$(grep -E '^docker.io/library/busybox:' "$ROOT/airgap/images.txt")"
SERVED="${SERVED_DEPLOYMENT:-granite}"
results=(); failed=0
pass() { results+=("PASS  $1"); printf '  PASS  %s\n' "$1"; }
fail() { results+=("FAIL  $1"); printf '  FAIL  %s\n' "$1"; failed=1; }
step() { printf '\n== %s\n' "$*"; }

served="$(kubectl -n inference get deployment "$SERVED" -o jsonpath='{.spec.template.spec.volumes[0].image.reference}')"
model="$(sed -E 's#.*/models/([^@]+)@.*#\1#' <<<"$served")"
retired="$REG/models/plant-retired@$(cat "$STATE/plant-retired.digest")"
next="$REG/models/plant-next@$(cat "$STATE/plant-next.digest")"

# render <before|overlap|after>: the model policy, trusting the operator's
# key, both, or the next key alone. Rendered from admission/verify-models.yaml
# itself, so the drill rotates the policy that runs, not a copy of it.
render() {
  python3 - "$ROOT/admission/verify-models.yaml" "$STATE/operator.pub" "$STATE/next.pub" "$1" <<'PY'
import sys
policy, op, nxt = (open(f).read() for f in sys.argv[1:4])
phase = sys.argv[4]
key = lambda k: k.strip().replace("\n", "\n            ")
text = policy.replace("@OPERATOR_KEY@", key(op))
if phase != "before":
    block = ("    - name: next\n      cosign:\n        key:\n          data: |\n            %s\n"
             "        ctlog:\n          insecureIgnoreTlog: true\n          insecureIgnoreSCT: true\n") % key(nxt)
    text = text.replace("  validations:\n", block + "  validations:\n", 1)
    text = text.replace("[attestors.operator]", "[attestors.operator, attestors.next]" if phase == "overlap" else "[attestors.next]")
print(text)
PY
}

# admitted <ref>: whether the API server, through Kyverno, admits a pod that
# mounts this model (a server-side dry run: nothing is created).
admitted() {
  kubectl apply --dry-run=server -f - >/dev/null 2>&1 <<EOF
{"apiVersion":"v1","kind":"Pod","metadata":{"name":"rotation-probe","namespace":"inference"},"spec":{
 "automountServiceAccountToken":false,
 "securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}},
 "containers":[{"name":"c","image":"$BUSYBOX","command":["sleep","3600"],
  "securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}},
  "volumeMounts":[{"name":"model","mountPath":"/models","readOnly":true}]}],
 "volumes":[{"name":"model","image":{"reference":"$1","pullPolicy":"IfNotPresent"}}]}}
EOF
}

# until_admitted <ref> <yes|no>: Kyverno reads a changed policy a moment
# after it is applied; wait up to a minute for the answer to turn.
until_admitted() {
  for _ in $(seq 1 30); do
    if admitted "$1"; then [ "$2" = yes ] && return 0; else [ "$2" = no ] && return 0; fi
    sleep 2
  done
  return 1
}

judge() {  # judge <yes|no> <ref> <what>
  if admitted "$2"; then got=yes; else got=no; fi
  if [ "$got" = "$1" ]; then pass "$3"; else fail "$3 (it was $([ "$got" = yes ] && echo admitted || echo refused))"; fi
}

step "1. before: the operator's key"
judge no "$next" "a model signed with the next key alone is refused while the policy trusts the operator's key"
judge yes "$retired" "control: a model signed with the operator's key alone is admitted"
judge yes "$served" "control: the served model, $model, is admitted"

step "2. overlap: both keys"
render overlap | kubectl apply -f - >/dev/null
if until_admitted "$next" yes; then pass "with both keys trusted, the model signed with the next key is admitted"
else fail "with both keys trusted, the model signed with the next key is still refused a minute later"; fi
judge yes "$retired" "with both keys trusted, the model signed with the operator's key is still admitted"
bundle_pem="$STATE/bundle.pem"
SSL_CERT_FILE="$bundle_pem" COSIGN_PASSWORD="" cosign sign --key "$STATE/next.key" --use-signing-config=false \
  --tlog-upload=false --yes "$served" >/dev/null 2>&1 \
  && SSL_CERT_FILE="$bundle_pem" COSIGN_PASSWORD="" cosign attest --key "$STATE/next.key" --type cyclonedx \
       --predicate "$STATE/$model.mlbom.json" --use-signing-config=false --tlog-upload=false --yes "$served" >/dev/null 2>&1
signed=$?
if [ $signed -eq 0 ]; then pass "the operator signed the served model and its AI-BOM with the next key, inside the boundary"
else fail "the served model could not be signed with the next key (cosign exit $signed)"; fi

step "3. after: the next key alone"
render after | kubectl apply -f - >/dev/null
if until_admitted "$retired" no; then pass "with the operator's key retired, a model signed with it alone is refused, though admitted a moment before"
else fail "with the operator's key retired, a model signed with it alone is still admitted a minute later"; fi
judge yes "$next" "control: the model signed with the next key is admitted"
judge yes "$served" "the served model, signed again with the next key, is admitted"
kubectl -n inference rollout restart "deployment/$SERVED" >/dev/null
if kubectl -n inference rollout status "deployment/$SERVED" --timeout=300s >/dev/null 2>&1; then
  pass "restarted under the next key alone, the served model came back"
else
  fail "restarted under the next key alone, the served model did not come back: $(kubectl -n inference get events --sort-by=.lastTimestamp 2>/dev/null | tail -2 | tr -s ' ' | cut -c1-200)"
fi

step "4. the policy as it was"
render before | kubectl apply -f - >/dev/null
until_admitted "$retired" yes || fail "the policy as it was did not take hold again"

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
