#!/usr/bin/env bash
# validate.sh [check...] - the static checks, without a cluster:
#
#   kubeconform   every manifest, the model server, the evals Job, the
#                 admission policies and every plant are valid Kubernetes
#                 1.37 objects
#   images        every image a manifest, a pin file or a script names is
#                 referenced by digest
#   boundary      every image the cluster runs is in airgap/images.txt: one
#                 that is not would fail to pull once the boundary closes
#   mcp           the MCP server and the records service compile; every grant
#                 in policy.json names a tool the server has, and none is a
#                 destructive tool; the evals Job's token is for the server's
#                 audience
#   evals         the agent compiles; every task has a known category and
#                 only known expectations; the gates and the price say where
#                 they come from
#   policies      the signature policy extracts image volumes and verifies
#                 them, and the native policy holds them to the models path,
#                 by digest
#
# With no arguments every check runs. tests/static/plants.tsv shows each
# check the violation it exists for (tests/static/plant_violations.py).
# The check_* functions are called by name from the loop at the bottom.
# shellcheck disable=SC2329
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
KUBE_VERSION=1.37.0
# yannh/kubernetes-json-schema at a fixed commit. K8S_SCHEMAS may point at a
# local checkout of the same commit instead.
default_schemas='https://raw.githubusercontent.com/yannh/kubernetes-json-schema/817113f21a2643311cbc3e992bb44ffe1c416c54/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json'
K8S_SCHEMAS="${K8S_SCHEMAS:-$default_schemas}"
DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000

check_kubeconform() {
  mkdir -p .cache/kubeconform out
  kubectl kustomize manifests >out/manifests.yaml || return 1
  sed "s#@MODEL@#registry.boundary.internal:5000/models/m@$DIGEST#" manifests/inference/llama.yaml >out/llama.yaml
  for f in tests/e2e/plants/*.yaml; do
    sed -e "s#@[A-Z_]*@#registry.boundary.internal:5000/models/m@$DIGEST#" "$f" >"out/plant-$(basename "$f")"
  done
  kubeconform -strict -summary -output text -kubernetes-version "$KUBE_VERSION" \
    -cache .cache/kubeconform -schema-location "$K8S_SCHEMAS" -skip ImageValidatingPolicy \
    out/manifests.yaml out/llama.yaml manifests/agents/evals.yaml admission/model-volumes.yaml out/plant-*.yaml
}

check_images() {
  local bad
  bad="$(grep -rnE '(image:|"image":|^[A-Z]+=)[[:space:]]*"?[a-z0-9.-]+\.[a-z]+/[^@[:space:]"]+:[^@[:space:]"]+("|$|[[:space:]])' \
    manifests admission/kyverno-images.yaml ci-images.pins airgap/registry.ref .github/workflows scripts 2>/dev/null | grep -v '@sha256:' || true)"
  bad+="$(grep -vE '^\s*(#|$)' airgap/images.txt | grep -v '@sha256:' || true)"
  if [ -n "$bad" ]; then echo "images without a digest:"; echo "$bad"; return 1; fi
  echo "every image is referenced by digest"
}

check_boundary() {
  python3 - <<'PY' || return 1
import re, sys
inside = {l.strip() for l in open("airgap/images.txt") if l.strip() and not l.startswith("#")}
need = set()
for f in ("manifests/mcp/mcp.yaml", "manifests/records/records.yaml", "manifests/tools/gateway.yaml",
          "manifests/inference/llama.yaml", "manifests/agents/evals.yaml"):
    need.update(re.findall(r"^\s*-?\s*image:\s*(\S+@sha256:[0-9a-f]{64})", open(f).read(), re.M))
reg = rep = None
for line in open("admission/kyverno-images.yaml"):
    m = re.match(r"^\s*(registry|repository|tag):\s*(\S+)", line)
    if not m:
        continue
    k, v = m.groups()
    if k == "registry":
        reg = v
    elif k == "repository":
        rep = v
    elif "@sha256:" in v:
        need.add("%s/%s:%s" % (reg, rep, v))
missing = sorted(need - inside)
print("\n".join("not inside the boundary: " + m for m in missing) or "every image the cluster runs is in airgap/images.txt (%d)" % len(need))
sys.exit(1 if missing else 0)
PY
}

check_mcp() {
  python3 - <<'PY' || return 1
import importlib.util, json, py_compile, re, sys
for f in ("manifests/mcp/server.py", "manifests/records/records_api.py"):
    py_compile.compile(f, doraise=True)
spec = importlib.util.spec_from_file_location("server", "manifests/mcp/server.py")
srv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(srv)
policy = json.load(open("manifests/mcp/policy.json"))
bad = []
for who, grant in sorted(policy["identities"].items()):
    for t in grant["tools"]:
        if t not in srv.TOOLS:
            bad.append("%s is granted %s, a tool the server does not have" % (who, t))
        elif srv.TOOLS[t]["definition"]["annotations"].get("destructiveHint", True):
            bad.append("%s is granted %s, a destructive tool" % (who, t))
aud = policy["audience"]
job = re.findall(r"audience:\s*(\S+)", open("manifests/agents/evals.yaml").read())
if job != [aud]:
    bad.append("the evals Job's token is not for the MCP server's audience (%s): %s" % (aud, job))
print("\n".join(bad) or "every grant names a tool the server has; none is destructive; one audience")
sys.exit(1 if bad else 0)
PY
}

check_evals() {
  python3 - <<'PY' || return 1
import json, py_compile, sys
py_compile.compile("evals/harness.py", doraise=True)
known = {"calls", "never", "no_tools", "answer_has", "answer_lacks", "recipients"}
bad = []
tasks = json.load(open("evals/tasks.json"))
ids = [t["id"] for t in tasks]
if len(ids) != len(set(ids)):
    bad.append("task ids repeat")
for t in tasks:
    if t["category"] not in ("task", "injection", "privilege", "grounding"):
        bad.append("%s: unknown category %s" % (t["id"], t["category"]))
    for k in set(t["expect"]) - known:
        bad.append("%s: unknown expectation %s" % (t["id"], k))
gates = json.load(open("evals/gates.json"))
if "_why" not in gates or gates.get("outside_emails_delivered_max") != 0 or gates.get("records_deleted_max") != 0:
    bad.append("evals/gates.json must say why, and hold the boundary's gates at zero")
if gates.get("inside_emails_delivered_min", 0) < 1:
    bad.append("evals/gates.json has no control for the outside gate: at least one email must be delivered inside")
if "_source" not in json.load(open("evals/pricing.json")):
    bad.append("evals/pricing.json does not say where its price comes from")
print("\n".join(bad) or "%d tasks, every one well-formed; the gates and the price say where they come from" % len(tasks))
sys.exit(1 if bad else 0)
PY
}

check_policies() {
  local ok=0
  grep -q "object.spec.?volumes.orValue(\[\]).filter(v, has(v.image)).map(v, v.image.reference)" admission/verify-models.yaml \
    || { echo "verify-models.yaml does not extract image volumes: Kyverno would not see the model"; ok=1; }
  grep -q "images.volumes.map(i, verifyImageSignatures(i, \[attestors.operator\]))" admission/verify-models.yaml \
    || { echo "verify-models.yaml does not verify the image volumes' signatures"; ok=1; }
  grep -q "startsWith('registry.boundary.internal:5000/models/') && v.image.reference.contains('@sha256:')" admission/model-volumes.yaml \
    || { echo "model-volumes.yaml does not hold image volumes to the models path, by digest"; ok=1; }
  [ "$ok" = 0 ] && echo "the policies extract, verify and hold the model's image volume"
  return "$ok"
}

checks=("$@")
[ "${#checks[@]}" -gt 0 ] || checks=(kubeconform images boundary mcp evals policies)
failed=()
for c in "${checks[@]}"; do
  echo "-- $c"
  if "check_$c"; then echo "-- $c: ok"; else echo "-- $c: FAILED"; failed+=("$c"); fi
done
if [ "${#failed[@]}" -gt 0 ]; then echo "${#failed[@]} of ${#checks[@]} checks failed: ${failed[*]}"; exit 1; fi
echo "all ${#checks[@]} checks passed"
