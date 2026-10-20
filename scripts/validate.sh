#!/usr/bin/env bash
# validate.sh [check...] - the static checks, without a cluster:
#
#   kubeconform   every manifest, the model server, the evals Job, the
#                 admission policies and every plant are valid Kubernetes
#                 1.37 objects
#   images        every image a manifest, a pin file or a script names is
#                 referenced by digest
#   boundary      every image the cluster runs is in airgap/images.txt: one
#                 that is not would fail to pull once the boundary closes; the
#                 registry inside lets anyone read and one account write, its
#                 password handed over on stdin (ADR 2)
#   mcp           the MCP server and the records service compile; every grant
#                 in policy.json, an agent's or a person's, names a tool the
#                 server has, and none is a destructive tool; the evals Job's
#                 token is for the server's audience; a person's token is for
#                 an audience of its own; and the server, run here, gives an
#                 agent acting for a person what both are granted and no more
#                 (ADR 15)
#   evals         the agent compiles; every task has a known category and
#                 only known expectations; the gates and the price say where
#                 they come from
#   policies      the signature policy extracts image volumes and verifies
#                 them, and the native policy holds them to the models path,
#                 by digest
#   gateway       every caller of the model gateway needs a token for its
#                 audience, the evals Job holds one, and every quota is keyed
#                 on the token's subject, never on a header the caller writes;
#                 every caller has a token budget beside its request quota,
#                 and every route goes to a model backend, where tokens are
#                 counted, never straight to a Service
#   docs          every command in docs/engagement.md is one the e2e workflow
#                 runs, its tag is the latest release, and the README lists
#                 every decision record
#   frontier      the one way out (ADR 14) stays one: the host's firewall
#                 opens Anthropic's published API range, on TCP 443, from the
#                 egress node alone; the job runs on main only, holds its
#                 OIDC permission alone and reads no stored secret; the
#                 gateway's backend reads its token from a Secret, never a
#                 key written in; and the egress node's admission policy
#                 still refuses all three ways onto the node, exempting only
#                 kube-system and the gateway's namespace
#   mlbom         every model's AI-BOM, written from its line in
#                 models/models.lock by scripts/mlbom.py, is a valid
#                 CycloneDX 1.6 document (cyclonedx-cli, pinned in
#                 ci-images.pins; needs Docker), with every bom-ref unique and
#                 every dependency naming one that exists
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
  sed -e "s#@MODEL@#registry.boundary.internal:5000/models/m@$DIGEST#" -e "s#@NAME@#llama#g" -e "s#@ALIAS@#m#g" manifests/inference/llama.yaml >out/llama.yaml
  for f in tests/e2e/plants/*.yaml tests/e2e/plants-frontier/*.yaml; do
    sed -e "s#@[A-Z_]*@#registry.boundary.internal:5000/models/m@$DIGEST#" "$f" >"out/plant-$(basename "$f")"
  done
  kubeconform -strict -summary -output text -kubernetes-version "$KUBE_VERSION" \
    -cache .cache/kubeconform -schema-location "$K8S_SCHEMAS" -skip ImageValidatingPolicy \
    out/manifests.yaml out/llama.yaml manifests/agents/evals.yaml admission/model-volumes.yaml admission/carried-images.yaml admission/egress-node.yaml out/plant-*.yaml || return 1
  # The gateway's own kinds are CRDs the pinned schemas do not carry; the rest
  # of the file, the namespace and the network policies, is checked.
  kubeconform -strict -summary -output text -kubernetes-version "$KUBE_VERSION" \
    -cache .cache/kubeconform -schema-location "$K8S_SCHEMAS" \
    -skip Gateway,HTTPRoute,ReferenceGrant,AgentgatewayPolicy,AgentgatewayParameters,AgentgatewayBackend manifests/gateway/gateway.yaml manifests/gateway/route.yaml manifests/gateway/frontier.yaml
}

check_images() {
  local bad
  bad="$(grep -rnE '(image:|"image":|^[A-Z]+=)[[:space:]]*"?[a-z0-9.-]+\.[a-z]+/[^@[:space:]"]+:[^@[:space:]"]+("|$|[[:space:]])' \
    manifests admission/kyverno-images.yaml ci-images.pins airgap/registry.ref .github/workflows scripts 2>/dev/null | grep -v '@sha256:' || true)"
  bad+="$(grep -vE '^\s*(#|$)' airgap/images.txt | grep -v '@sha256:' || true)"
  # The node image reaches the cluster outside the bundle (README, What it
  # does not do); its pin is the one thing that says which node it was.
  bad+="$(grep -nE '^\s*image:' kind/*.yaml | grep -v '@sha256:' || true)"
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
# The gateway's images, rendered by its chart and its controller rather than
# written in a manifest here, are named in gateway/gateway.lock.
for line in open("gateway/gateway.lock"):
    f = line.split()
    if len(f) >= 4 and f[0] == "image":
        need.add(f[3])
missing = ["not inside the boundary: " + m for m in sorted(need - inside)]
# Who may write to the registry inside (ADR 2): anyone reads, one account
# writes, with a password that is never an argument.
import json
zot = json.load(open("airgap/zot.json"))["http"]
acl = zot.get("accessControl", {}).get("repositories", {})
writers = {u for r in acl.values() for p in r.get("policies", []) for u in p.get("users", [])
           if set(p.get("actions", [])) & {"create", "update", "delete"}}
if not zot.get("auth", {}).get("htpasswd") or any(r.get("anonymousPolicy") != ["read"] for r in acl.values()) \
        or not acl or writers != {"loader"}:
    missing.append("airgap/zot.json does not hold writing to one account, loader, with reads open and nothing more")
airgap = open("scripts/airgap.sh").read()
if "--password-stdin" not in airgap or re.search(r"oras login[^\n]*\s-p\s", airgap):
    missing.append("scripts/airgap.sh does not hand the registry's password to oras on stdin")
print("\n".join(missing) or "every image the cluster runs is in airgap/images.txt (%d); the registry lets anyone read and only loader write" % len(need))
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
for who, grant in sorted(list(policy["identities"].items()) + list(policy.get("people", {}).items())):
    for t in grant["tools"]:
        if t not in srv.TOOLS:
            bad.append("%s is granted %s, a tool the server does not have" % (who, t))
        elif srv.TOOLS[t]["definition"]["annotations"].get("destructiveHint", True):
            bad.append("%s is granted %s, a destructive tool" % (who, t))
# A value JSON Schema refuses must be refused here too: the server checks
# every argument itself, so its reading of a pattern is the boundary's.
for tool, value in (("send_email", {"to": "dana@acme.example\n", "subject": "s", "body": "b"}),
                    ("records_lookup", {"customer_id": "C1042\n"})):
    if srv.validate(srv.TOOLS[tool]["definition"]["inputSchema"], value) is None:
        bad.append("%s accepts %r, which its schema's pattern refuses" % (tool, value))
aud = policy["audience"]
# The token the agent shows the MCP server (the Job holds one for the model
# gateway too, for that audience alone).
job = re.findall(r"name: mcp-token\n(?:.*\n){0,6}?\s*audience:\s*(\S+)", open("manifests/agents/evals.yaml").read())
if job != [aud]:
    bad.append("the evals Job's MCP token is not for the MCP server's audience (%s): %s" % (aud, job))
# A person's token is for an audience of its own, or it would pass as an
# agent's (the MCP server's) or a model caller's (the gateway's).
gateway_aud = re.findall(r"audiences: \[(.*?)\]", open("manifests/gateway/gateway.yaml").read())
if not policy.get("people") or policy.get("people_audience") in (aud, *gateway_aud):
    bad.append("policy.json names no people, or their audience (%s) is one an agent's token is made for" % policy.get("people_audience"))
if "secretName: people-tokens" not in open("manifests/agents/evals.yaml").read():
    bad.append("the evals Job does not mount the people's tokens, so no task is asked for anyone")
# The server itself, run here: what an agent acting for a person may do.
s = srv.Server(policy)
agent = "system:serviceaccount:agents:support-agent"
def tools_for(person):
    return [t["name"] for t in s.handle(agent, {"method": "tools/list"}, person)[0]["tools"]]
def outcome(person, name, args):
    try:
        return s.handle(agent, {"method": "tools/call", "params": {"name": name, "arguments": args}}, person)[1]
    except srv.Refused as e:
        return e.decision
for person, grant in policy["people"].items():
    allowed = sorted(set(grant["tools"]) & set(policy["identities"][agent]["tools"]))
    if sorted(tools_for(person)) != allowed:
        bad.append("acting for %s the server lists %s, not what both are granted, %s" % (person, tools_for(person), allowed))
    if grant["customers"] != "*":
        other = next(c for p in policy["people"].values() if p["customers"] != "*" for c in p["customers"] if c not in grant["customers"])
        if outcome(person, "records_lookup", {"customer_id": other}) != "out_of_scope":
            bad.append("acting for %s the server would look up %s, a customer not theirs" % (person, other))
if tools_for("system:serviceaccount:people:nobody"):
    bad.append("the server lists tools for a person policy.json does not know")
print("\n".join(bad) or "every grant names a tool the server has; none is destructive; a pattern refuses a trailing newline; the agent's MCP token is for the server's audience; acting for a person, the server gives what both are granted, down to the person's customers")
sys.exit(1 if bad else 0)
PY
}

check_evals() {
  python3 - <<'PY' || return 1
import json, py_compile, sys
py_compile.compile("evals/harness.py", doraise=True)
known = {"calls", "never", "no_tools", "answer_has", "answer_lacks", "answer_addresses_from", "recipients"}
bad = []
tasks = json.load(open("evals/tasks.json"))
ids = [t["id"] for t in tasks]
if len(ids) != len(set(ids)):
    bad.append("task ids repeat")
for t in tasks:
    if t["category"] not in ("task", "injection", "privilege", "grounding", "person"):
        bad.append("%s: unknown category %s" % (t["id"], t["category"]))
    if "as" in t and "system:serviceaccount:people:" + t["as"] not in json.load(open("manifests/mcp/policy.json"))["people"]:
        bad.append("%s: asked for %s, a person policy.json does not know" % (t["id"], t["as"]))
    for k in set(t["expect"]) - known:
        bad.append("%s: unknown expectation %s" % (t["id"], k))
gates = json.load(open("evals/gates.json"))
if "_why" not in gates or gates.get("outside_emails_delivered_max") != 0 or gates.get("records_deleted_max") != 0:
    bad.append("evals/gates.json must say why, and hold the boundary's gates at zero")
if gates.get("control_email_must_arrive") is not True:
    bad.append("evals/gates.json has no control for the outside gate: the harness's control email must arrive")
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
  grep -q "verifyAttestationSignatures(i, attestations.mlbom, \[attestors.operator\])" admission/verify-models.yaml \
    || { echo "verify-models.yaml does not verify the model's AI-BOM"; ok=1; }
  grep -q "c.licenses.exists(l, l.license.id in \['Apache-2.0', 'MIT'\])" admission/verify-models.yaml \
    || { echo "verify-models.yaml does not hold the model's licence to the allowlist"; ok=1; }
  grep -q "variables.images.all(i, variables.carried.exists(d, i.endsWith('@' + d)))" admission/carried-images.yaml \
    || { echo "carried-images.yaml does not hold every pod's images to the digests the bundle carried"; ok=1; }
  grep -q "parameterNotFoundAction: Deny" admission/carried-images.yaml \
    || { echo "carried-images.yaml admits everything when its list of digests is missing"; ok=1; }
  [ "$ok" = 0 ] && echo "the policies extract, verify and hold the model's image volume, read its AI-BOM's licence, and hold every pod to what the bundle carried"
  return "$ok"
}

check_gateway() {
  local ok=0 aud keys requests budgets backends
  { grep -q '^    jwtAuthentication:$' manifests/gateway/gateway.yaml && grep -q '^      mode: Strict$' manifests/gateway/gateway.yaml; } \
    || { echo "gateway.yaml does not require a token of every caller (jwtAuthentication, mode Strict)"; ok=1; }
  aud="$(sed -n 's/^ *audiences: \[\(.*\)\]$/\1/p' manifests/gateway/gateway.yaml)"
  [ -n "$aud" ] || { echo "gateway.yaml names no audience: any token the cluster signs would do"; ok=1; }
  grep -A6 'name: models-token' manifests/agents/evals.yaml | grep -q "audience: $aud\$" \
    || { echo "the evals Job holds no token for the gateway's audience ($aud)"; ok=1; }
  # A quota keyed on anything but the token's subject is one a caller can pick.
  keys="$(grep -oE 'key: [^,}]+' manifests/gateway/gateway.yaml | sort -u)"
  [ "$keys" = "key: jwt.sub" ] || { echo "a quota in gateway.yaml is keyed on something other than the token's subject: $(tr '\n' ' ' <<<"$keys")"; ok=1; }
  # A token budget for every caller that has a request quota (ADR 12).
  requests="$(grep -cE '\brequests: [0-9]+' manifests/gateway/gateway.yaml)"
  budgets="$(grep -cE '\btokens: [0-9]+' manifests/gateway/gateway.yaml)"
  if [ "$requests" -eq 0 ] || [ "$budgets" != "$requests" ]; then
    echo "gateway.yaml has $requests request quotas and $budgets token budgets: a caller without a budget can spend any number of tokens"; ok=1
  fi
  # On a route straight to a Service the gateway never reads an answer's
  # usage, and a token budget there is accepted and refuses nothing.
  backends="$(awk '/^ *backendRefs:/ {f = 1; next} f && /^ *- / {print; next} {f = 0}' manifests/gateway/route.yaml)"
  if [ -z "$backends" ] || grep -qv 'kind: AgentgatewayBackend' <<<"$backends"; then
    echo "route.yaml sends a model's requests somewhere other than an AgentgatewayBackend, where no token is counted: $backends"; ok=1
  fi
  [ "$ok" = 0 ] && echo "every caller of the gateway needs a token for $aud, the agent holds one, every quota is keyed on its subject, every caller has a token budget, and every route goes to a model backend"
  return "$ok"
}

check_docs() {
  python3 - <<'PY' || return 1
import os, re, sys
bad = []
e2e = open(".github/workflows/e2e.yml").read()
runbook = open("docs/engagement.md").read()
for block in re.findall(r"```bash\n(.*?)```", runbook, re.S):
    for line in block.splitlines():
        for cmd in re.findall(r"\./(?:scripts|tests)/[\w./-]+(?: [a-z]+)?", line.split("#")[0]):
            if not re.search(re.escape(cmd) + r"(?![\w-])", e2e):
                bad.append("docs/engagement.md runs %s, which the e2e workflow does not" % cmd)
tag = re.findall(r"git checkout (\S+)", runbook)
latest = re.search(r"^## \[(\d+\.\d+\.\d+)\]", open("CHANGELOG.md").read(), re.M)
if not latest or tag != ["v" + latest.group(1)]:
    bad.append("docs/engagement.md checks out %s, the latest release is v%s" % (tag, latest and latest.group(1)))
# The table itself, not a mention elsewhere in the README.
table = re.search(r"^## Decisions\n(.*?)(?=^## )", open("README.md").read(), re.M | re.S)
readme = table.group(1) if table else ""
for f in sorted(os.listdir("docs/decisions")):
    if re.match(r"\d{4}-.*\.md$", f) and "(docs/decisions/%s)" % f not in readme:
        bad.append("the README's decisions table does not list docs/decisions/%s" % f)
print("\n".join(bad) or "every command in the engagement plan is one the e2e runs, its tag is the latest release, and the README lists every decision")
sys.exit(1 if bad else 0)
PY
}

check_frontier() {
  python3 - <<'PY' || return 1
import re, sys
bad = []
fs = open("scripts/frontier.sh").read()
# The hole: Anthropic's published inbound range for the API, and no wider.
if re.findall(r"^RANGE=(\S+)$", fs, re.M) != ["160.79.104.0/23"]:
    bad.append("scripts/frontier.sh opens %s, not Anthropic's published API range 160.79.104.0/23"
               % re.findall(r"^RANGE=(\S+)$", fs, re.M))
rule = re.search(r'^rule\(\) \{ echo "(.*)"; \}$', fs, re.M)
rule = rule.group(1) if rule else ""
if '-s $(node_ip "$(egress_node)")' not in rule:
    bad.append("the firewall rule in scripts/frontier.sh is not the egress node's alone: any pod on any node could use it")
if "-d $RANGE -p tcp --dport 443 -j ACCEPT" not in rule:
    bad.append("the firewall rule in scripts/frontier.sh is not to the range on TCP 443 alone")
wf = open(".github/workflows/frontier.yml").read()
if "if: github.ref == 'refs/heads/main'" not in wf:
    bad.append("frontier.yml may run off main, where the federation rule mints nothing and a branch's code would hold the token")
if "secrets." in wf:
    bad.append("frontier.yml reads a stored secret: the API token is minted per run, and no key is stored")
if "id-token" in wf.split("\njobs:")[0]:
    bad.append("frontier.yml grants id-token: write to the whole workflow, not to its one job")
fr = open("manifests/gateway/frontier.yaml").read()
if not re.search(r"^ +secretRef: \{name: anthropic-token\}$", fr, re.M) or re.search(r"^ +key: ", fr, re.M):
    bad.append("the gateway's Anthropic backend does not read its token from the Secret anthropic-token alone")
eg = open("admission/egress-node.yaml").read()
for needle, what in (("t.?key.orValue('') == 'boundary.heyvaldemar.com/egress'", "that tolerates the egress node's taint"),
                     ("t.?operator.orValue('Equal') == 'Exists'", "that tolerates every taint"),
                     ("!has(object.spec.nodeName)", "that names its node")):
    if needle not in eg:
        bad.append("admission/egress-node.yaml no longer refuses a pod %s" % what)
exempt = re.search(r"operator: NotIn, values: \[([^\]]*)\]", eg)
if not exempt or sorted(v.strip() for v in exempt.group(1).split(",")) != ["gateway", "kube-system"]:
    bad.append("admission/egress-node.yaml exempts %s, not kube-system and gateway alone" % (exempt and exempt.group(1)))
if "validationActions: [Deny]" not in eg:
    bad.append("admission/egress-node.yaml's binding does not deny")
print("\n".join(bad) or "the one way out is Anthropic's API range on TCP 443 from the egress node alone; the job runs on main with no stored secret; "
      "the gateway's token comes from a Secret; only the gateway may run on the egress node")
sys.exit(1 if bad else 0)
PY
}

check_mlbom() {
  local img ok=0 n=0 name url sha lic
  img="$(sed -n 's/^CYCLONEDX_IMAGE=//p' ci-images.pins)"
  mkdir -p out/mlbom
  while read -r name url sha lic _; do
    n=$((n + 1))
    python3 scripts/mlbom.py "$name" "$url" "$sha" "$lic" >"out/mlbom/$name.json" || { echo "$name: no AI-BOM could be written"; ok=1; continue; }
    docker run --rm -v "$PWD/out/mlbom:/b:ro" "$img" validate --input-file "/b/$name.json" \
        --input-format json --input-version v1_6 --fail-on-errors >/dev/null 2>&1 \
      || { echo "$name: its AI-BOM is not valid CycloneDX 1.6"; ok=1; }
    # The schema cannot see this: every bom-ref unique, and every dependency
    # naming one that exists.
    python3 - "out/mlbom/$name.json" <<'PY' || { echo "$name: its AI-BOM's references do not hold"; ok=1; }
import json, sys
bom = json.load(open(sys.argv[1]))
refs = []
def walk(c):
    if isinstance(c, dict):
        if "bom-ref" in c:
            refs.append(c["bom-ref"])
        for v in c.values():
            walk(v)
    elif isinstance(c, list):
        for v in c:
            walk(v)
walk(bom)
dupes = sorted({r for r in refs if refs.count(r) > 1})
missing = sorted({r for d in bom.get("dependencies", []) for r in [d["ref"]] + d.get("dependsOn", []) if r not in refs})
if dupes or missing:
    sys.exit("duplicate bom-refs %s, dependencies on unknown refs %s" % (dupes, missing))
PY
  done < <(grep -vE '^\s*(#|$)' models/models.lock)
  [ "$ok" = 0 ] && echo "every model's AI-BOM is valid CycloneDX 1.6 ($n models)"
  return "$ok"
}

checks=("$@")
[ "${#checks[@]}" -gt 0 ] || checks=(kubeconform images boundary mcp evals policies gateway docs frontier mlbom)
failed=()
for c in "${checks[@]}"; do
  echo "-- $c"
  if "check_$c"; then echo "-- $c: ok"; else echo "-- $c: FAILED"; failed+=("$c"); fi
done
if [ "${#failed[@]}" -gt 0 ]; then echo "${#failed[@]} of ${#checks[@]} checks failed: ${failed[*]}"; exit 1; fi
echo "all ${#checks[@]} checks passed"
