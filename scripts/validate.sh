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
#   vault         the records credential from Vault (ADR 24): no records
#                 key in any manifest or script, and no Secret mounted in the
#                 records service or the MCP server; no TTL in Vault above
#                 the records service's limit, and that limit 60 s; Vault's
#                 Kubernetes role takes mcp/mcp-server alone, by a token for
#                 Vault's audience, to read one path; only the MCP server
#                 reaches Vault; Vault runs its own configuration, Raft and
#                 TLS, not dev mode; and the records service's check, run
#                 here against tokens signed by a key made for the check,
#                 takes the valid one and refuses fourteen others
#   evals         the agent compiles; every task has a known category and
#                 only known expectations; the gates and the price say where
#                 they come from
#   policies      the signature policy extracts image volumes and verifies
#                 them, and the native policy holds them to the models path,
#                 by digest; every licence of every model in the AI-BOM must
#                 be on the list, and an SPDX expression is refused
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
#   aws           the AWS run (ADR 18): aws/ declares no internet gateway, NAT,
#                 egress-only gateway, peering, transit attachment or route;
#                 its Terraform tests pass against a mocked provider (no route
#                 out, endpoints from the VPC only, a resolver that refuses
#                 names outside AWS and fails closed, the API from the
#                 operator's /32, every role under the boundary, the GPU
#                 node in every zone that offers each of its types and in
#                 no subnet with a public address); and the workflow runs
#                 on main only and reads no stored secret
#   gpu           the AWS run EC2 gives no GPU (ADR 19, 2026-11-11): the
#                 GPU step survives only the failure scripts/aws.sh capacity
#                 passes; the miss is said and counted by a step GitHub's
#                 API finds by name; the GPU steps run only on a node that
#                 was made; the second scheduled miss in a row fails; no
#                 step's failure is passed over; and scripts/aws.sh's part
#                 passes tests/static/aws-gpu-capacity.sh against an AWS
#                 and a GitHub made of files (capacity alone is a miss, any
#                 other failure the run's; the count of misses in a row;
#                 a GitHub that does not answer)
#   gke           the GKE run (ADR 22): gke/ declares no router, NAT,
#                 external address, peering or VPN, and two routes, to
#                 restricted.googleapis.com and private.googleapis.com; its
#                 Terraform tests pass against mocked providers (a network
#                 made without its internet route, egress denied but to the
#                 restricted door and, from the node alone, the private one, a
#                 response policy that refuses every other name, the API from
#                 the operator's /32, NetworkPolicies enforced, the registry
#                 read by the nodes and Kyverno alone), and so do the
#                 bootstrap's (one immutable subject, each service account
#                 from its own workflow, a sweep that creates nothing, the
#                 budget); no service account key anywhere; both workflows
#                 run on main only, outside any environment, and read no
#                 stored secret; the run's teardown removes its own state;
#                 and scripts/gke.sh's sweep and leftovers pass
#                 tests/static/gke-sweep.sh against a Google Cloud and a
#                 Terraform made of files (a state whose resources are gone,
#                 a destroy that cannot read its state, a run still going)
#   aks           the AKS run (ADR 23): aks/ declares no public address,
#                 NAT gateway, route table, firewall, peering or gateway, and
#                 every subnet turns Azure's default outbound access off; its
#                 Terraform tests pass against mocked providers (outbound type
#                 none, egress denied but inside the network, a resolver
#                 policy that refuses every name but the registry's and the
#                 network's own, the API from the operator's /32, AKS's own
#                 images from the registry inside, NetworkPolicies enforced,
#                 the registry reached through its private endpoint); and the
#                 run's workflow holds to main, a typed SPEND or the schedule
#                 behind its variable, runs its cloud jobs in the federated
#                 environments, and reads no stored secret
#   mlbom         every model's AI-BOM, written from its line in
#                 models/models.lock by scripts/mlbom.py, is a valid
#                 CycloneDX 1.6 document (cyclonedx-cli, pinned in
#                 ci-images.pins; needs Docker), with every bom-ref unique and
#                 every dependency naming one that exists; and an SPDX
#                 expression is concluded to the ids the site allows, or
#                 refused, as nine cases say it must be
#   results       each cloud run's results, kept (ADR 25): cloud-results.yml
#                 follows exactly the three cloud workflows by the names they
#                 have, on main, holds a run to this repository's own code
#                 and to the schedule or a dispatch by hand, signs in one job
#                 and writes the branch in another, runs in no environment,
#                 reads no stored secret and logs in to no cloud; and
#                 scripts/cloud-results.py passes tests/static/cloud-results.py
#                 against a GitHub made of files (a run on a branch, a fork's
#                 run, another workflow's, one a pull request started, a file
#                 that is not the one GitHub reports, a record already kept)
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
  sed -e "s#@MODEL@#registry.boundary.internal:5000/models/m@$DIGEST#" -e "s#@NAME@#llama-gpu#g" -e "s#@ALIAS@#m#g" manifests/inference/llama-gpu.yaml >out/llama-gpu.yaml
  sed -e "s#@MODEL@#registry.boundary.internal:5000/models/m@$DIGEST#" -e "s#@NAME@#embed#g" -e "s#@ALIAS@#m#g" manifests/inference/embed.yaml >out/embed.yaml
  for f in tests/e2e/plants/*.yaml tests/e2e/plants-frontier/*.yaml; do
    sed -e "s#@[A-Z_]*@#registry.boundary.internal:5000/models/m@$DIGEST#" "$f" >"out/plant-$(basename "$f")"
  done
  kubeconform -strict -summary -output text -kubernetes-version "$KUBE_VERSION" \
    -cache .cache/kubeconform -schema-location "$K8S_SCHEMAS" -skip ImageValidatingPolicy \
    out/manifests.yaml out/llama.yaml out/llama-gpu.yaml out/embed.yaml aws/storage-class.yaml manifests/gpu/device-plugin.yaml manifests/gpu/measure.yaml manifests/gpu/capacity.yaml manifests/ha/disruption-budgets.yaml manifests/agents/evals.yaml admission/model-volumes.yaml admission/carried-images.yaml admission/egress-node.yaml out/plant-*.yaml || return 1
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
  bad+="$(grep -vE '^\s*(#|$)' airgap/images.txt airgap/images-gpu.txt | grep -v '@sha256:' || true)"
  # The node image reaches the cluster outside the bundle (README, What it
  # does not do); its pin is the one thing that says which node it was.
  bad+="$(grep -nE '^\s*image:' kind/*.yaml | grep -v '@sha256:' || true)"
  if [ -n "$bad" ]; then echo "images without a digest:"; echo "$bad"; return 1; fi
  echo "every image is referenced by digest"
}

check_boundary() {
  python3 - <<'PY' || return 1
import re, sys
inside = {l.strip() for f in ("airgap/images.txt", "airgap/images-gpu.txt")
          for l in open(f) if l.strip() and not l.startswith("#")}
need = set()
for f in ("manifests/mcp/mcp.yaml", "manifests/records/records.yaml", "manifests/tools/gateway.yaml", "manifests/vault/vault.yaml",
          "manifests/inference/llama.yaml", "manifests/agents/evals.yaml",
          "manifests/inference/llama-gpu.yaml", "manifests/inference/embed.yaml", "manifests/gpu/device-plugin.yaml", "manifests/gpu/capacity.yaml"):
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
# The door the GPU measurement opens into inference while it runs (ADR 19):
# for the measurement's own pod, from its own namespace, on the servers' one
# port; and that namespace reaches nothing but the servers and DNS.
docs = open("manifests/gpu/measure.yaml").read().split("\n---\n")
ingress = next((d for d in docs if "name: from-the-measurement" in d), "").partition("ingress:")[2]
if ingress.count("- from:") != 1 or re.findall(r"port: (\d+)", ingress) != ["8080"] or not re.search(
        r"kubernetes.io/metadata.name: measure\n\s+podSelector:\n\s+matchLabels:\n\s+app.kubernetes.io/name: capacity\n", ingress):
    missing.append("manifests/gpu/measure.yaml: the door into inference is not for the measurement's pod alone, on port 8080")
egress = next((d for d in docs if "name: to-the-model-servers" in d), "").partition("egress:")[2]
if egress.count("- to:") != 2 or re.findall(r"port: (\d+)", egress) != ["8080", "53", "53"] or re.search(r"-\s*\{\}|Selector: \{\}|ipBlock", egress):
    missing.append("manifests/gpu/measure.yaml: the measurement's namespace reaches more than the model servers and DNS")
airgap = open("scripts/airgap.sh").read()
if "--password-stdin" not in airgap or re.search(r"oras login[^\n]*\s-p\s", airgap):
    missing.append("scripts/airgap.sh does not hand the registry's password to oras on stdin")
print("\n".join(missing) or "every image the cluster runs is in airgap/images.txt or images-gpu.txt (%d); the registry lets anyone read and only loader write" % len(need))
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
    if grant["customers"] != "*" and "records_lookup" in allowed:
        other = next(c for p in policy["people"].values() if p["customers"] != "*" for c in p["customers"] if c not in grant["customers"])
        if outcome(person, "records_lookup", {"customer_id": other}) != "out_of_scope":
            bad.append("acting for %s the server would look up %s, a customer not theirs" % (person, other))
# The documents (ADR 21). Each document in turn is made the one nearest the
# question; across all of them a person's searches must return exactly the
# documents both the person and the agent may read: none beyond, so a
# filter that lets anything through fails, and every one within, so a
# search that returns nothing does not pass.
srv.DOCUMENTS_DIR = "manifests/mcp/documents"
docs = srv.documents()
known = {"all", "account-managers", "finance"}
for d in docs:
    if d.get("audience") not in known or not d.get("id") or not d.get("title"):
        bad.append("document %s has no id, no title, or an audience no one is granted: %s" % (d.get("id"), d.get("audience")))
N = len(docs)
for person, grant in policy["people"].items():
    if "search_documents" not in grant["tools"]:
        continue
    may = set(grant.get("documents", [])) & set(policy["identities"][agent].get("documents", []))
    within = {d["id"] for d in docs if d.get("audience") in may}
    seen = set()
    for k in range(N):
        srv.embed = lambda texts, k=k: [[1.0 if i == 0 else 0.0 for i in range(N)]] if texts[0].startswith("search_query") \
            else [[1.0 if i == (j + k) % N else 0.0 for i in range(N)] for j in range(len(texts))]
        srv._index = None
        res = srv.Server(policy).handle(agent, {"method": "tools/call", "params": {
            "name": "search_documents", "arguments": {"query": "anything"}}}, person)
        seen |= set(res[3]["documents"]) if len(res) > 3 else set()
    if seen != within:
        bad.append("acting for %s searches returned %s beyond and missed %s of what both may read (%s)"
                   % (person, sorted(seen - within), sorted(within - seen), sorted(may)))
if tools_for("system:serviceaccount:people:nobody"):
    bad.append("the server lists tools for a person policy.json does not know")
print("\n".join(bad) or "every grant names a tool the server has; none is destructive; a pattern refuses a trailing newline; the agent's MCP token is for the server's audience; acting for a person, the server gives what both are granted, down to the person's customers and the documents both may read")
sys.exit(1 if bad else 0)
PY
}

check_vault() {
  python3 - <<'PY' || return 1
import base64, glob, hashlib, importlib.util, json, os, re, secrets, sys, tempfile, time
bad = []
# 1. No records key, anywhere it could come back: no Secret by that name, no
# key file, no secret mounted in the records service or the MCP server.
for f in sorted(glob.glob("manifests/**/*", recursive=True) + glob.glob("scripts/*")):
    if os.path.isdir(f) or f == "scripts/validate.sh" or "__pycache__" in f:
        continue
    text = open(f, encoding="utf-8", errors="replace").read()
    for pat in (r"records-api-key\b", r"/var/run/secrets/records\b", r"\bRECORDS_KEY(_FILE)?\b", r"token_urlsafe"):
        if re.search(pat, text):
            bad.append("%s matches %s: the static records key is back" % (f, pat))
for f in ("manifests/records/records.yaml", "manifests/mcp/mcp.yaml"):
    if re.search(r"^\s*(secret:|secretName:|secretKeyRef:)", open(f).read(), re.M):
        bad.append("%s mounts or reads a Secret" % f)
# 2. The records service's limit, and no TTL in Vault above it.
spec = importlib.util.spec_from_file_location("records_api", "manifests/records/records_api.py")
rec = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rec)
if rec.MAX_LIFETIME != 60:
    bad.append("the records service takes credentials that live %s s; ADR 24 sets 60" % rec.MAX_LIFETIME)
def seconds(v):
    m = re.fullmatch(r"(\d+)([smh]?)", str(v))
    return int(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600}[m.group(2)] if m else 10**9
setup = json.load(open("manifests/vault/setup.json"))
k8s, key, role = setup["kubernetes_role"], setup["key"], setup["role"]
for what, v in (("the credential role's ttl", role["ttl"]), ("the login token's token_ttl", k8s["token_ttl"]),
                ("the login token's token_max_ttl", k8s["token_max_ttl"])):
    if seconds(v) > rec.MAX_LIFETIME:
        bad.append("%s is %s, above the records service's limit of %d s" % (what, v, rec.MAX_LIFETIME))
# 3. One service account may get a credential: the MCP server's, by a token
# for Vault's audience, the one its pod projects.
mcp = open("manifests/mcp/mcp.yaml").read()
projected = re.findall(r"serviceAccountToken:\n\s*path: token\n\s*audience: (\S+)", mcp)
if k8s["bound_service_account_names"] != ["mcp-server"] or k8s["bound_service_account_namespaces"] != ["mcp"]:
    bad.append("Vault's Kubernetes role takes %s in %s, not mcp-server in mcp alone"
               % (k8s["bound_service_account_names"], k8s["bound_service_account_namespaces"]))
if k8s.get("audience") != "vault.boundary.heyvaldemar.com" or projected != [k8s.get("audience")]:
    bad.append("Vault's role audience (%s) is not Vault's own, or not the one the MCP server's token is for (%s)" % (k8s.get("audience"), projected))
if k8s["token_policies"] != ["records-caller"] or not k8s.get("token_no_default_policy"):
    bad.append("the MCP server's Vault token carries %s, not records-caller alone" % k8s["token_policies"])
hcl = re.sub(r"#.*", "", open("manifests/vault/records-caller.hcl").read())
if re.findall(r'path\s+"([^"]+)"\s*\{\s*capabilities\s*=\s*\[([^\]]*)\]\s*\}', hcl) != [("identity/oidc/token/records-api", '"read"')]:
    bad.append("records-caller grants more than reading identity/oidc/token/records-api")
if key["allowed_client_ids"] != ["records-api"] or role["client_id"] != "records-api" or key["algorithm"] != "RS256" \
        or "records:delete" in role["scope"].split():
    bad.append("the records key signs for %s, the role is for %s with %s, scope %r" % (key["allowed_client_ids"], role["client_id"], key["algorithm"], role["scope"]))
# 4. Only the MCP server reaches Vault.
docs = open("manifests/network-policies.yaml").read().split("\n---\n")
vault_np = [d for d in docs if re.search(r"^\s*namespace: vault$", d, re.M)]
deny = [d for d in vault_np if "name: default-deny" in d and "podSelector: {}" in d and "policyTypes: [Ingress, Egress]" in d]
ingress = [d.partition("ingress:")[2] for d in vault_np if "ingress:" in d]
if not deny or len(ingress) != 1 or ingress[0].count("- from:") != 1 or re.findall(r"port: (\d+)", ingress[0]) != ["8200"] \
        or re.search(r"ipBlock|Selector: \{\}", ingress[0]) or not re.search(
            r"kubernetes.io/metadata.name: mcp\n\s+podSelector:\n\s+matchLabels:\n\s+app.kubernetes.io/name: mcp-server\n", ingress[0]):
    bad.append("manifests/network-policies.yaml: Vault is not denied by default and reached by the MCP server alone, on 8200")
# 5. Not dev mode: the server's own configuration, integrated storage, TLS.
vy, hc = open("manifests/vault/vault.yaml").read(), open("manifests/vault/vault.hcl").read()
if "command: [vault, server, -config=/vault/config/vault.hcl]" not in vy or "-dev" in vy or 'storage "raft"' not in hc \
        or "tls_cert_file" not in hc or "tls_disable" in hc:
    bad.append("Vault does not run its own configuration with integrated storage and TLS, or runs in dev mode")
# 6. The records service's check, against tokens signed here by a key made
# for this check: the valid one is taken (the control), every other refused.
def prime(bits):
    while True:
        n = secrets.randbits(bits) | (1 << (bits - 1)) | 1
        if any(n % p == 0 for p in (3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37)):
            continue
        d, r = n - 1, 0
        while d % 2 == 0:
            d, r = d // 2, r + 1
        for _ in range(32):
            x = pow(secrets.randbelow(n - 3) + 2, d, n)
            if x in (1, n - 1):
                continue
            for _ in range(r - 1):
                x = pow(x, 2, n)
                if x == n - 1:
                    break
            else:
                break
        else:
            return n
e = 65537
while True:
    p, q = prime(1024), prime(1024)
    phi = (p - 1) * (q - 1)
    if p != q and phi % e and (p * q).bit_length() == 2048:
        break
n, d = p * q, pow(e, -1, phi)
b64 = lambda raw: base64.urlsafe_b64encode(raw).rstrip(b"=").decode()
num = lambda i: b64(i.to_bytes((i.bit_length() + 7) // 8, "big"))
keys = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
json.dump({"keys": [{"kty": "RSA", "alg": "RS256", "use": "sig", "kid": "k1", "n": num(n), "e": num(e)}]}, keys)
keys.close()
rec.KEYS_FILE = keys.name
def sign(signed):
    k = 256
    t = rec.SHA256_INFO + hashlib.sha256(signed).digest()
    em = int.from_bytes(b"\x00\x01" + b"\xff" * (k - len(t) - 3) + b"\x00" + t, "big")
    return pow(em, d, n).to_bytes(k, "big")
now = int(time.time())
def jwt(header=None, **over):
    c = {"iss": rec.ISSUER, "aud": "records-api", "iat": now, "exp": now + 60, "scope": "records:read outbox:send", "sub": "s"}
    c.update(over)
    c = {k: v for k, v in c.items() if v is not None}
    h = b64(json.dumps(header or {"alg": "RS256", "kid": "k1"}).encode()) + "." + b64(json.dumps(c).encode())
    return h + "." + b64(sign(h.encode()))
valid = jwt()
h, body, s = valid.split(".")
other = json.loads(base64.urlsafe_b64decode(body + "=="))
other["scope"] = "records:read outbox:send records:delete"
import hmac as _hmac
hs_head = b64(json.dumps({"alg": "HS256", "kid": "k1"}).encode()) + "." + body
cases = [
    ("a valid credential (the control)", valid, "records:read", "ok"),
    ("an expired credential", jwt(iat=now - 61, exp=now - 1), "records:read", 401),
    ("a credential for another audience", jwt(aud="reports-api"), "records:read", 401),
    ("a credential for two audiences", jwt(aud=["records-api", "reports-api"]), "records:read", 401),
    ("a credential from another issuer", jwt(iss="https://kubernetes.default.svc.cluster.local"), "records:read", 401),
    ("a credential that lives an hour", jwt(exp=now + 3600), "records:read", 401),
    ("a credential issued in the future", jwt(iat=now + 60, exp=now + 120), "records:read", 401),
    ("a credential with no expiry", jwt(exp=None), "records:read", 401),
    ("a credential by a key Vault does not publish", jwt(header={"alg": "RS256", "kid": "k2"}), "records:read", 401),
    ("alg none", b64(json.dumps({"alg": "none", "kid": "k1"}).encode()) + "." + body + ".", "records:read", 401),
    ("HS256 keyed with the public key", hs_head + "." + b64(_hmac.new(num(n).encode(), hs_head.encode(), hashlib.sha256).digest()), "records:read", 401),
    ("a payload changed after signing", h + "." + b64(json.dumps(other).encode()) + "." + s, "records:read", 401),
    ("a signature cut short", h + "." + body + "." + b64(base64.urlsafe_b64decode(s + "==")[:-1]), "records:read", 401),
    ("a valid credential for a delete, a scope no role issues", valid, "records:delete", 403),
    ("a scope that only starts with the one needed", jwt(scope="records:readall"), "records:read", 403),
]
for what, tok, need, want in cases:
    got = rec.verify(tok, need)
    status = "ok" if isinstance(got, dict) else got[0]
    if status != want:
        bad.append("records_api.verify: %s gave %s, expected %s" % (what, status, want))
os.unlink(keys.name)
print("\n".join(bad) or "no records key anywhere; no Vault TTL above the records service's 60 s; one service account, mcp/mcp-server, by Vault's audience, may get a credential, to read one path; only the MCP server reaches Vault; Vault runs its own configuration with Raft and TLS; and the records service takes the valid credential and refuses %d others" % (len(cases) - 1))
sys.exit(1 if bad else 0)
PY
}

check_evals() {
  python3 - <<'PY' || return 1
import json, py_compile, sys
py_compile.compile("evals/harness.py", doraise=True)
known = {"calls", "never", "no_tools", "answer_has", "answer_lacks", "answer_addresses_from", "answer_claims_no_plan", "recipients"}
bad = []
tasks = json.load(open("evals/tasks.json"))
ids = [t["id"] for t in tasks]
if len(ids) != len(set(ids)):
    bad.append("task ids repeat")
for t in tasks:
    if t["category"] not in ("task", "injection", "privilege", "grounding", "person", "documents"):
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
if gates.get("documents_beyond_rights_max") != 0 or gates.get("control_search_must_find") is not True:
    bad.append("evals/gates.json lets a document beyond a person's rights through, or drops its control: the harness's own search must find the finance document for finance (ADR 21)")
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
  grep -qF "c.licenses.all(l, has(l.license) && has(l.license.id) && l.license.id in ['Apache-2.0', 'MIT'])" admission/verify-models.yaml \
    || { echo "verify-models.yaml does not hold every licence entry to the allowlist"; ok=1; }
  grep -qF "predicate.components.all(c, c.type != 'machine-learning-model' ||" admission/verify-models.yaml \
    || { echo "verify-models.yaml does not hold every model in the AI-BOM to it"; ok=1; }
  grep -qF "c.?licenses.orValue([]).all(l, !has(l.expression))" admission/verify-models.yaml \
    || { echo "verify-models.yaml reads past an SPDX expression instead of refusing it"; ok=1; }
  # Fail closed: with Kyverno down its webhooks stay, and the API server
  # refuses what it cannot ask about (tests/e2e/gameday.sh). Ignore would
  # admit every model unchecked for as long as Kyverno is away.
  for f in admission/verify-models.yaml admission/model-volumes.yaml admission/carried-images.yaml admission/egress-node.yaml admission/kyverno-guard.yaml; do
    grep -qE '^  failurePolicy: Fail$' "$f" || { echo "$f does not fail closed (failurePolicy: Fail)"; ok=1; }
  done
  # And when Kyverno takes its webhooks away as it stops, the API server's
  # own guard refuses every model until they are back.
  if ! { grep -qF "w.name == 'ivpol.validate.kyverno.svc-fail-finegrained-verify-models' &&" admission/kyverno-guard.yaml \
          && grep -qE '^    name: kyverno-resource-validating-webhook-cfg$' admission/kyverno-guard.yaml \
          && grep -qE '^    parameterNotFoundAction: Deny$' admission/kyverno-guard.yaml; }; then
    echo "kyverno-guard.yaml does not refuse models while Kyverno's webhook for verify-models is missing"; ok=1
  fi
  grep -q "variables.images.all(i, variables.carried.exists(d, i.endsWith('@' + d)))" admission/carried-images.yaml \
    || { echo "carried-images.yaml does not hold every pod's images to the digests the bundle carried"; ok=1; }
  grep -q "parameterNotFoundAction: Deny" admission/carried-images.yaml \
    || { echo "carried-images.yaml admits everything when its list of digests is missing"; ok=1; }
  # Every image a pod uses: an image volume's files are read like any other
  # (kubernetes-supply-chain-admission's ADR 6 found the gap there).
  for part in "ephemeralContainers" "v.image.reference" "pods/ephemeralcontainers"; do
    grep -qF "$part" admission/carried-images.yaml \
      || { echo "carried-images.yaml does not read $part: an image could arrive there unchecked"; ok=1; }
  done
  [ "$ok" = 0 ] && echo "the policies extract, verify and hold the model's image volume, hold every licence of every model in its AI-BOM to the list, and hold every pod to what the bundle carried"
  return "$ok"
}

check_aws() {
  local ok=0 out
  if grep -nE 'resource "aws_(internet_gateway|egress_only_internet_gateway|nat_gateway|route|vpc_peering_connection|ec2_transit_gateway_vpc_attachment)"' aws/*.tf; then
    echo "aws/ declares a way out of the VPC"; ok=1
  fi
  if grep -nE '^[[:space:]]+route[[:space:]]*\{' aws/*.tf; then echo "aws/ declares a route"; ok=1; fi
  grep -qF "if: github.ref == 'refs/heads/main' && (inputs.confirm == 'SPEND' || (github.event_name == 'schedule' && vars.AWS_VALIDATION_ENABLED == 'true'))" .github/workflows/aws.yml \
    || { echo "the AWS run is not held to main, a typed SPEND, or the schedule behind its variable"; ok=1; }
  if grep -n 'secrets\.' .github/workflows/aws.yml; then echo "the AWS run reads a stored secret; it has GitHub's OIDC token"; ok=1; fi
  # Vault's volume (ADR 24): the cluster's default class, gp3 and encrypted,
  # deleted with its claim; and the claim released before the destroy, since
  # no Terraform state holds the volume, then none left after it.
  python3 - <<'PY' || ok=1
import re, sys
sc = open("aws/storage-class.yaml").read()
bad = [what for what, pat in (
    ("the EBS CSI driver", r"(?m)^provisioner: ebs\.csi\.aws\.com$"),
    ("gp3", r'(?m)^  type: gp3$'),
    ("encrypted", r'(?m)^  encrypted: "true"$'),
    ("made where its pod is scheduled", r"(?m)^volumeBindingMode: WaitForFirstConsumer$"),
    ("deleted with its claim", r"(?m)^reclaimPolicy: Delete$"),
    ("the cluster's default", r'(?m)^    storageclass\.kubernetes\.io/is-default-class: "true"$')) if not re.search(pat, sc)]
wf = open(".github/workflows/aws.yml").read()
if "kubectl apply -f aws/storage-class.yaml" not in wf:
    bad.append("applied before the tool side")
release = wf.partition("- name: Vault's volume, released before the destroy")[2].partition("- name:")[0]
if "if: always()" not in release or "./scripts/vault.sh release" not in release or "./scripts/aws.sh volumes 0" not in release:
    bad.append("Vault's claim released before the destroy, whatever happened, and no volume left")
# The release comes after the last step that may reach Vault: it is the up
# job's last step.
up = wf.partition("\n  up:\n")[2].partition("\n  down:\n")[0]
if "- name:" in up.partition("- name: Vault's volume, released before the destroy")[2]:
    bad.append("the release the up job's last step, after everything that reaches Vault")
if wf.partition("  down:")[2].count("./scripts/aws.sh volumes 0") != 1:
    bad.append("no volume left after the destroy")
if bad:
    print("Vault's volume on AWS: not " + "; not ".join(bad)); sys.exit(1)
PY
  # The GPU node's card (ADR 19, 2026-11-09): each type the node group may
  # be given, named by the GPU it carries, the A10G as the fallback, and a
  # GPU that is not the one its type carries refused.
  local t n want got
  while IFS='|' read -r t n want; do
    got="$(./scripts/gpu.sh card "$t" "$n" 2>/dev/null)" || got=REFUSED
    [ "$got" = "$want" ] || { echo "gpu.sh card $t '$n' says '$got', not '$want'"; ok=1; }
  done <<'CARDS'
g6.xlarge|NVIDIA L4|NVIDIA L4 (g6.xlarge)
g5.xlarge|NVIDIA A10G|NVIDIA A10G (g5.xlarge), the fallback when EC2 has no L4
g6.xlarge|NVIDIA A10G|REFUSED
g5.xlarge|NVIDIA L4|REFUSED
g5.xlarge||REFUSED
CARDS
  if ! command -v terraform >/dev/null; then echo "check aws needs terraform"; return 1; fi
  if ! out="$(cd aws && terraform init -backend=false -input=false -lockfile=readonly >/dev/null 2>&1 && terraform test -no-color 2>&1)"; then
    echo "aws/'s tests failed: $(grep -E 'Error|error_message|Failure' <<<"$out" | head -5 | tr '\n' ' ')"; ok=1
  fi
  [ "$ok" = 0 ] && echo "the VPC declares no way out, the resolver refuses names outside AWS and fails closed, the API answers the operator alone, and the run is main's, with no stored secret"
  return "$ok"
}

check_gpu() {
  local ok=0 out
  # The run EC2 gives no GPU (ADR 19, 2026-11-11): the one failure the GPU
  # step survives is the one scripts/aws.sh capacity passes; the miss is
  # said and counted by a step GitHub's API finds by name; the second
  # scheduled miss in a row fails; and no step's failure is passed over.
  python3 - <<'PY' || ok=1
import importlib.util, re, sys
spec = importlib.util.spec_from_file_location("ec2_capacity", "scripts/ec2-capacity.py")
ec2 = importlib.util.module_from_spec(spec); spec.loader.exec_module(ec2)
wf = open(".github/workflows/aws.yml").read()
up = wf.partition("\n  up:\n")[2].partition("\n  down:\n")[0]
def step(name):
    return up.partition("      - name: %s\n" % name)[2].partition("\n      - name:")[0] + "\n"
bad = []
if "    name: %s\n" % ec2.JOB not in up or any(up.count("      - name: %s\n" % n) != 1 for n in (ec2.ASKED, ec2.MISSED)):
    bad.append("the job and the two steps under the names scripts/ec2-capacity.py reads from GitHub's API")
asked, missed = step(ec2.ASKED), step(ec2.MISSED)
survives = """          if terraform -chdir=aws apply -input=false -auto-approve -var-file="$PWD/run.tfvars.json" -var gpu=true; then
            echo "node=made" >> "$GITHUB_OUTPUT"
          else
            ./scripts/aws.sh capacity
            echo "node=none" >> "$GITHUB_OUTPUT"
          fi
"""
if survives not in asked or wf.count("node=none") != 1:
    bad.append("a GPU step that survives only the failure aws.sh capacity passes")
if "        if: env.WITH_GPU == 'true' && steps.gpu_clock.outputs.node == 'none'\n" not in missed or "        run: ./scripts/aws.sh missed\n" not in missed:
    bad.append("the miss said and counted by aws.sh missed, on a miss alone")
for name in ("The GPU node's type", "A GPU beside the CPU, the same signed model, measured", "A larger model on the same GPU, through the evals"):
    if "        if: env.WITH_GPU == 'true' && steps.gpu_clock.outputs.node == 'made'\n" not in step(name):
        bad.append("'%s' only on a GPU node that was made" % name)
limit = re.search(r'(?m)^  GPU_MISSES_IN_A_ROW: "(\d+)"$', wf)
if not limit or limit.group(1) != "2":
    bad.append("the second scheduled miss in a row failing the run")
if "continue-on-error" in wf:
    bad.append("every step's failure the run's own")
if "needs.up.outputs.gpu_node != 'none' &&" not in wf.partition("\n  down:\n")[2]:
    bad.append("a cost table with no GPU node when EC2 gave none")
if bad:
    print("the AWS run with no GPU to be had: not " + "; not ".join(bad)); sys.exit(1)
PY
  if ! out="$(bash tests/static/aws-gpu-capacity.sh 2>&1)"; then
    echo "the GPU capacity tests failed: $(grep '^FAIL' <<<"$out" | head -3 | tr '\n' ' ')"; ok=1
  fi
  [ "$ok" = 0 ] && echo "a run EC2 gives no GPU goes on only when capacity was the one reason, says so, and fails on the second scheduled miss in a row"
  return "$ok"
}

check_gke() {
  local ok=0 out dir routes
  if grep -nE 'resource "google_compute_(router|router_nat|address|global_address|network_peering|vpn_gateway|ha_vpn_gateway|vpn_tunnel|external_vpn_gateway|interconnect_attachment|instance)"' gke/*.tf; then
    echo "gke/ declares a way out of the network"; ok=1
  fi
  if grep -nE '^[[:space:]]*access_config[[:space:]]*\{' gke/*.tf; then echo "gke/ gives something an external address"; ok=1; fi
  routes="$(cat gke/*.tf | grep -cE '^resource "google_compute_route"' || true)"
  [ "$routes" = 2 ] || { echo "gke/ declares $routes routes; there are two, to Google's two API front doors"; ok=1; }
  if ! { [ "$(grep -E '^  dest_range[[:space:]]+=' gke/network.tf | sed -E 's/.*= //' | sort | tr '\n' ' ')" = "local.google_apis local.google_images " ] \
          && grep -qE '^  google_apis[[:space:]]+= "199\.36\.153\.4/30"$' gke/network.tf \
          && grep -qE '^  google_images[[:space:]]+= "199\.36\.153\.8/30"$' gke/network.tf; }; then
    echo "a route goes somewhere other than restricted.googleapis.com and private.googleapis.com"; ok=1
  fi
  if grep -rn --include='*.tf' 'google_service_account_key' gke/; then echo "gke/ makes a service account key; every credential is federated"; ok=1; fi
  grep -qF "if: github.ref == 'refs/heads/main' && (inputs.confirm == 'SPEND' || (github.event_name == 'schedule' && vars.GKE_VALIDATION_ENABLED == 'true'))" .github/workflows/gke.yml \
    || { echo "the GKE run is not held to main, a typed SPEND, or the schedule behind its variable"; ok=1; }
  # A job in an environment carries that environment in its subject, which
  # the federation does not admit: the run would fail at its first step.
  if grep -nE '^[[:space:]]+environment:' .github/workflows/gke.yml .github/workflows/gke-sweep.yml; then
    echo "a GKE job runs in an environment; the federation admits main's subject alone"; ok=1
  fi
  if grep -n 'secrets\.' .github/workflows/gke.yml .github/workflows/gke-sweep.yml; then echo "a GKE workflow reads a stored secret; it has GitHub's OIDC token"; ok=1; fi
  grep -qF 'run: ./scripts/gke.sh drop' .github/workflows/gke.yml \
    || { echo "the GKE run's teardown leaves its state behind, for the next run to trip on (41038578800)"; ok=1; }
  # GKE keeps a disk made for a claim when the cluster goes (ADR 24): Vault's
  # claim is released before the destroy, whatever happened, none is left
  # after it, and the daily sweep takes one a run left.
  python3 - <<'PY' || ok=1
import sys
wf = open(".github/workflows/gke.yml").read()
release = wf.partition("- name: Vault's volume, released before the destroy")[2].partition("- name:")[0]
bad = []
if "if: always()" not in release or "./scripts/vault.sh release" not in release or "./scripts/gke.sh volumes 0" not in release:
    bad.append("Vault's claim released before the destroy, whatever happened, and no disk left")
up = wf.partition("\n  up:\n")[2].partition("\n  down:\n")[0]
if "- name:" in up.partition("- name: Vault's volume, released before the destroy")[2]:
    bad.append("the release the up job's last step, after everything that reaches Vault")
if wf.partition("  down:")[2].count("./scripts/gke.sh volumes 0") != 1:
    bad.append("no disk left after the destroy")
if "./scripts/gke.sh volumes sweep" not in open(".github/workflows/gke-sweep.yml").read():
    bad.append("the daily sweep taking a disk a run left")
if bad:
    print("Vault's disk on GKE: not " + "; not ".join(bad)); sys.exit(1)
PY
  # gke.sh needs bash 4 or later (inherit_errexit), as the runner has.
  local b sweep_bash=""
  for b in bash /opt/homebrew/bin/bash /usr/local/bin/bash; do
    # shellcheck disable=SC2016  # the version is the other bash's, expanded there
    if command -v "$b" >/dev/null && [ "$("$b" -c 'echo "${BASH_VERSINFO[0]}"')" -ge 4 ]; then sweep_bash="$b"; break; fi
  done
  if [ -z "$sweep_bash" ]; then echo "check gke needs bash 4 or later for the sweep's tests"; ok=1
  elif ! out="$("$sweep_bash" tests/static/gke-sweep.sh 2>&1)"; then
    echo "the sweep's tests failed: $(grep '^FAIL' <<<"$out" | head -3 | tr '\n' ' ')"; ok=1
  fi
  if ! command -v terraform >/dev/null; then echo "check gke needs terraform"; return 1; fi
  for dir in gke gke/bootstrap; do
    if ! out="$(cd "$dir" && terraform init -backend=false -input=false -lockfile=readonly >/dev/null 2>&1 && terraform test -no-color 2>&1)"; then
      echo "$dir's tests failed: $(grep -E 'Error|error_message|Failure' <<<"$out" | head -5 | tr '\n' ' ')"; ok=1
    fi
  done
  [ "$ok" = 0 ] && echo "the network's ways out are Google's two API front doors, the private one for the node alone, the resolver refuses every other name, the API answers the operator alone, the federation admits main's two workflows by the immutable subject, and nothing holds a key"
  return "$ok"
}

check_aks() {
  local ok=0 out
  if grep -nE 'resource "(azurerm|azapi)_[a-z_]*(public_ip|nat_gateway|route_table|route|firewall|virtual_network_peering|virtual_network_gateway|vpn_gateway|express_route|bastion_host)[a-z_]*"' aks/*.tf; then
    echo "aks/ declares a way out of the network"; ok=1
  fi
  if grep -nE 'Microsoft\.Network/(publicIPAddresses|natGateways|routeTables|azureFirewalls|virtualNetworkGateways|bastionHosts)' aks/*.tf; then
    echo "aks/ declares a way out of the network through the Azure API"; ok=1
  fi
  local subnets off
  subnets="$(grep -cE '^resource "azurerm_subnet"' aks/network.tf || true)"
  off="$(grep -cE '^  default_outbound_access_enabled[[:space:]]+= false$' aks/network.tf || true)"
  [ "$subnets" = "$off" ] || { echo "aks/ has $subnets subnets and $off with default outbound access off"; ok=1; }
  grep -qE '^    outbound_type[[:space:]]+= "none"$' aks/cluster.tf || { echo "the AKS cluster's outbound type is not none"; ok=1; }
  # AKS's LocalDNS answers pods from the node, past the agent's DNS rule,
  # which names kube-dns: off, unless a run asks for the violation.
  grep -qE '^      localDNSProfile = \{ mode = var\.local_dns \? "Required" : "Disabled" \}$' aks/cluster.tf \
    || { echo "AKS's LocalDNS is not turned off on the node pool, but by var.local_dns"; ok=1; }
  if ! grep -qE '^resource "azapi_update_resource" "local_dns" \{$' aks/cluster.tf \
      || awk '/^resource "azapi_update_resource" "local_dns"/ {in_it = 1} in_it && /^  count / {found = 1} in_it && /^}/ {in_it = 0} END {exit !found}' aks/cluster.tf; then
    echo "the node pool's LocalDNS setting is not made on every run"; ok=1
  fi
  grep -qF "if: github.ref == 'refs/heads/main' && (inputs.confirm == 'SPEND' || (github.event_name == 'schedule' && vars.AZURE_VALIDATION_ENABLED == 'true'))" .github/workflows/aks.yml \
    || { echo "the AKS run is not held to main, a typed SPEND, or the schedule behind its variable"; ok=1; }
  # The federation's subjects name an environment; a cloud job outside it is
  # refused at its first step, and one in the wrong one acts as the wrong
  # identity.
  [ "$(grep -cE '^    environment: azure-validation$' .github/workflows/aks.yml)" = 2 ] \
    || { echo "aks.yml's two cloud jobs do not both run in azure-validation"; ok=1; }
  grep -qE '^    environment: azure-sweeper$' .github/workflows/aks-sweep.yml || { echo "aks-sweep.yml does not run in azure-sweeper"; ok=1; }
  if grep -n 'AZURE_SWEEP_CLIENT_ID' .github/workflows/aks.yml | grep -v '^[0-9]*:          SWEEP: '; then
    echo "aks.yml logs in as the sweep identity"; ok=1
  fi
  if grep -n 'AZURE_CREATE_CLIENT_ID' .github/workflows/aks-sweep.yml; then echo "aks-sweep.yml can act as the creation identity"; ok=1; fi
  if grep -n 'secrets\.' .github/workflows/aks.yml .github/workflows/aks-sweep.yml; then echo "an AKS workflow reads a stored secret; it has GitHub's OIDC token"; ok=1; fi
  if ! command -v terraform >/dev/null; then echo "check aks needs terraform"; return 1; fi
  if ! out="$(cd aks && terraform init -backend=false -input=false -lockfile=readonly >/dev/null 2>&1 && terraform test -no-color 2>&1)"; then
    echo "aks/'s tests failed: $(grep -E 'Error|error_message|Failure' <<<"$out" | head -5 | tr '\n' ' ')"; ok=1
  fi
  [ "$ok" = 0 ] && echo "the network declares no way out and AKS makes none, egress is denied but inside it, the resolver refuses every name but the registry's and the network's own, AKS's images come from the registry inside, the API answers the operator alone, and each workflow is main's, in its own federated environment, with no stored secret"
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
  # A model server that is gone is found out by the gateway in a second,
  # taken out of the rotation, and the request sent to another (ADR 20).
  local ct ms=""
  ct="$(sed -nE 's/^ *connectTimeout: ([0-9]+)(ms|s)$/\1 \2/p' manifests/gateway/route.yaml)"
  case "$ct" in *" ms") ms="${ct% ms}" ;; *" s") ms="$(( ${ct% s} * 1000 ))" ;; esac
  if [ -z "$ms" ] || [ "$ms" -gt 5000 ] || ! grep -qE '^ +consecutiveFailures: [0-9]+$' manifests/gateway/route.yaml \
     || ! grep -qE '^ +attempts: [1-9]$' manifests/gateway/route.yaml || ! grep -qE '^ +codes: \[[^]]*503' manifests/gateway/route.yaml; then
    echo "route.yaml lets a request wait on a model server that is gone: a connect timeout of seconds (${ct:-none}), an eviction and a retry on 503 are what stop it (ADR 20)"; ok=1
  fi
  [ "$ok" = 0 ] && echo "every caller of the gateway needs a token for $aud, the agent holds one, every quota is keyed on its subject, every caller has a token budget, every route goes to a model backend, and a model server that is gone is given up on in ${ms} ms and its requests sent to another"
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
  local img ok=0 n=0 name url sha lic rest
  img="$(sed -n 's/^CYCLONEDX_IMAGE=//p' ci-images.pins)"
  mkdir -p out/mlbom
  while read -r name url sha rest; do
    lic="${rest% *}"  # an SPDX expression may hold spaces; the digest is last
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
  # An SPDX expression is concluded where the BOM is made: to the first
  # reading the site's list allows, in the order written, or to no BOM at
  # all. One concluded BOM is held to the schema too.
  python3 - <<'PY' || ok=1
import json, subprocess, sys
url = "https://huggingface.co/plant/x/resolve/0000000000000000000000000000000000000000/model.gguf"
sha = "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881"
cases = [
    ("Apache-2.0 OR CC-BY-NC-4.0", ["Apache-2.0"]),
    ("CC-BY-NC-4.0 OR MIT", ["MIT"]),
    ("Apache-2.0 AND MIT", ["Apache-2.0", "MIT"]),
    ("(GPL-3.0-only OR MIT) AND Apache-2.0", ["MIT", "Apache-2.0"]),
    ("GPL-2.0-only WITH Classpath-exception-2.0 OR MIT", ["MIT"]),
    ("Apache-2.0 AND CC-BY-NC-4.0", None),
    ("CC-BY-NC-4.0 OR GPL-3.0-only", None),
    ("Apache-2.0 WITH LLVM-exception", None),
    ("Apache-2.0 or MIT", None),
]
bad = []
for expr, want in cases:
    r = subprocess.run([sys.executable, "scripts/mlbom.py", "x", url, sha, expr], capture_output=True, text=True)
    if want is None:
        if r.returncode == 0:
            bad.append("%r was written; it should have been refused" % expr)
        continue
    if r.returncode != 0:
        bad.append("%r was refused: %s" % (expr, r.stderr.strip()))
        continue
    c = json.loads(r.stdout)["components"][0]
    got = [e["license"]["id"] for e in c["licenses"] if e["license"].get("acknowledgement") == "concluded"]
    kept = [p["value"] for p in c["properties"] if p["name"] == "license-declared"]
    if got != want or kept != [expr]:
        bad.append("%r concluded to %s, declared %s; expected %s" % (expr, got, kept, want))
    else:
        open("out/mlbom/concluded.json", "w").write(r.stdout)
print("\n".join("mlbom.py: " + b for b in bad))
sys.exit(1 if bad else 0)
PY
  docker run --rm -v "$PWD/out/mlbom:/b:ro" "$img" validate --input-file /b/concluded.json \
      --input-format json --input-version v1_6 --fail-on-errors >/dev/null 2>&1 \
    || { echo "an AI-BOM with a concluded licence is not valid CycloneDX 1.6"; ok=1; }
  [ "$ok" = 0 ] && echo "every model's AI-BOM is valid CycloneDX 1.6 ($n models), and nine SPDX expressions conclude, or are refused, as they should"
  return "$ok"
}

check_results() {
  local ok=0 out
  python3 - <<'PY' || ok=1
import re, sys
wf = open(".github/workflows/cloud-results.yml").read()
script = open("scripts/cloud-results.py").read()
bad = []
names = [re.search(r"^name: (.+)$", open(".github/workflows/%s.yml" % c).read(), re.M).group(1) for c in ("aws", "gke", "aks")]
m = re.search(r"^  workflow_run:\n    workflows: \[(.+)\]\n    types: \[completed\]\n    branches: \[main\]$", wf, re.M)
if not m:
    bad.append("triggered by finished runs on main")
elif sorted(re.findall(r'"([^"]+)"', m.group(1))) != sorted(names):
    bad.append("following exactly the three cloud workflows, by the names they have (%s)" % ", ".join(names))
if re.search(r"^  (push|pull_request|pull_request_target|schedule|release):", wf, re.M):
    bad.append("started only by a finished cloud run or by hand")
guard = ("github.ref == 'refs/heads/main' && (github.event_name == 'workflow_dispatch' ||\n"
         "      (github.event.workflow_run.head_branch == 'main' &&\n"
         "      github.event.workflow_run.head_repository.full_name == github.repository &&\n"
         "      (github.event.workflow_run.event == 'schedule' || github.event.workflow_run.event == 'workflow_dispatch')))\n")
if guard not in wf:
    bad.append("held to main, to this repository's own code, and to the schedule or a dispatch by hand")
if not re.search(r"^permissions:\n  contents: read\n", wf, re.M):
    bad.append("read-only for every job that does not say otherwise")
sign = wf.partition("\n  sign:\n")[2].partition("\n  keep:\n")[0]
keep = wf.partition("\n  keep:\n")[2]
for grant, job, what in (("id-token: write", sign, "signing in the sign job alone"),
                         ("actions: read", sign, "reading runs in the sign job alone"),
                         ("contents: write", keep, "writing the branch in the keep job alone")):
    if wf.count(grant) != 1 or grant not in job:
        bad.append(what)
if re.search(r"^\s+environment:", wf, re.M) or "secrets." in wf:
    bad.append("outside every environment, reading no stored secret")
if re.search(r"configure-aws-credentials|google-github-actions|azure/login|setup-terraform|terraform |gcloud |aws-actions|\baz ", wf):
    bad.append("with no cloud login and no cloud tool")
if not re.search(r"^concurrency:\n  group: cloud-results\n  cancel-in-progress: false$", wf, re.M):
    bad.append("one run at a time, none cancelled")
if wf.count("persist-credentials: false") != wf.count("uses: actions/checkout@"):
    bad.append("checking out without leaving the token behind")
if any(not re.fullmatch(r"[^@\s]+@[0-9a-f]{40}", u) for u in re.findall(r"uses: (\S+)", wf)):
    bad.append("with every action pinned by commit")
if '.github/workflows/cloud-results.yml@refs/heads/main" \\' not in wf:
    bad.append("verifying its own signature as this workflow on main, and no wider")
if re.search(r"tarfile|unpack_archive|extractall|\.extract\(|subprocess|os\.system|\beval\(|\bexec\(", script):
    bad.append("reading the artifact in memory only and running nothing (scripts/cloud-results.py)")
if bad:
    print("cloud-results.yml: not " + "; not ".join(bad)); sys.exit(1)
PY
  if ! out="$(python3 tests/static/cloud-results.py 2>&1)"; then
    echo "scripts/cloud-results.py's cases failed: $(grep '^FAIL' <<<"$out" | head -3 | tr '\n' ' ')$(grep -q '^FAIL' <<<"$out" || tail -n 2 <<<"$out" | tr '\n' ' ')"; ok=1
  fi
  [ "$ok" = 0 ] && echo "a finished cloud run's results are kept only from main, this repository's own code and the three cloud workflows, by a workflow with no cloud credential that signs in one job and writes the branch in another, and $(grep -c '^PASS' <<<"$out") cases of what is kept and what is not hold"
  return "$ok"
}

checks=("$@")
[ "${#checks[@]}" -gt 0 ] || checks=(kubeconform images boundary mcp vault evals policies gateway docs frontier aws gpu gke aks mlbom results)
failed=()
for c in "${checks[@]}"; do
  echo "-- $c"
  if "check_$c"; then echo "-- $c: ok"; else echo "-- $c: FAILED"; failed+=("$c"); fi
done
if [ "${#failed[@]}" -gt 0 ]; then echo "${#failed[@]} of ${#checks[@]} checks failed: ${failed[*]}"; exit 1; fi
echo "all ${#checks[@]} checks passed"
