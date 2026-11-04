#!/usr/bin/env bash
# tests/e2e/vault.sh - the records credential from Vault (ADR 24), against
# the cluster as it runs: Vault, the MCP server and the records service,
# with real tokens and no model. Each refusal sits beside a call that must
# succeed from the same place.
#
#   1. what Kubernetes gives on its own, the record's premise: the API
#      server refuses a token shorter than ten minutes, and any service
#      account gets a token for the audience records-api
#   2. the records tool through the MCP server, with Vault's credential
#      (the control); the records service logs the caller's service
#      account; no records key anywhere: no Secret by that name, and no
#      Secret mounted in the records service or the MCP server
#   3. the credential: RS256, Vault's issuer, audience records-api, scope
#      records:read outbox:send, and a lifetime of 60 s (MEASURED, beside
#      the key it replaced, which had no expiry)
#   4. who may get one: Vault takes the MCP server's token for its audience
#      (the control) and refuses the agent's service account, another
#      service account in the MCP server's namespace, and the MCP server's
#      own token for the Kubernetes API; an agent pod cannot connect to
#      Vault while it reaches the MCP server (the control), and neither can
#      the records service
#   5. what the records service refuses: no credential, a random key, the
#      cluster's own token for records-api, a delete with a valid
#      credential (no role issues records:delete), a credential signed by
#      Vault's key for another audience (a role planted and removed), one
#      minted while Vault's TTL was raised to an hour (planted and put
#      back), and an expired one, read from its log with each reason
#   6. a pod with a Vault image the bundle did not carry is refused at
#      admission, and the one it carried is admitted (the control)
#   7. revocation, ROUNDS times: the MCP server's identity disabled in
#      Vault. How long until Vault refuses a new credential, until a
#      credential copied just before gets its first 401, and until the MCP
#      server's records tool stops, while its report tool still answers;
#      then enabled, and how long until the records tool is back (MEASURED)
#   8. Vault's audit names the MCP server's service account for every
#      credential it issued, and holds every login it refused
#   9. what Vault costs: its install time, its pod's memory and CPU, its
#      volume, and its image on the node (MEASURED)
#
# One process mints the tokens, keeps them in memory and makes the calls:
# no token, share or credential is printed, an argument or a file. The
# operator's token is read from .cache/airgap/vault/ (scripts/vault.sh).
# Appends to $E2E_RESULTS (JSON) when set.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=scripts/inside.sh
. "$ROOT/scripts/inside.sh"
PY="$(relocated "$(grep -E '^docker.io/library/python:' "$ROOT/airgap/images.txt")")"
VAULT_IMAGE="$(relocated "$(grep -E '^docker.io/hashicorp/vault:' "$ROOT/airgap/images.txt")")"
# Vault 2.2.0, an image the bundle never carried: the plant check 9 of
# tests/e2e/run.sh also tries.
UNCARRIED="$(relocated "$(sed -n 's/^ *image: //p' "$ROOT/tests/e2e/plants/vault-not-carried.yaml")")"

kubectl -n agents delete pod vault-probe --ignore-not-found --wait=true >/dev/null 2>&1
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: vault-probe, namespace: agents}
spec:
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: c
      image: $PY
      command: [sleep, "3600"]
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
EOF
kubectl -n agents wait pod/vault-probe --for=condition=Ready --timeout=120s >/dev/null

PYTHONPATH="$ROOT/scripts" python3 - "$ROOT" "${E2E_RESULTS:-}" "${ROUNDS:-3}" "$VAULT_IMAGE" "$UNCARRIED" <<'PY'
import base64, contextlib, json, os, random, re, secrets, socket, statistics, subprocess, sys, threading, time
import urllib.error, urllib.request
import vault_api as V

root, results, rounds, vault_image, uncarried = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
checks, measured = [], []
since = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
setup = json.load(open(os.path.join(root, "manifests", "vault", "setup.json")))
VAULT_AUD = setup["kubernetes_role"]["audience"]
LIMIT = 60

def check(ok, line):
    checks.append({"name": line, "passed": bool(ok)})
    print(("  PASS  " if ok else "  FAIL  ") + line, flush=True)

def measure(line):
    measured.append(line)
    print("  MEASURED  " + line, flush=True)

def step(s):
    print("\n== " + s, flush=True)

def kubectl(*args, stdin=None):
    return subprocess.run(["kubectl", *args], input=stdin, capture_output=True, text=True)

def token(ns, sa, audience=None, duration="10m"):
    args = ["-n", ns, "create", "token", sa, "--duration", duration] + (["--audience", audience] if audience else [])
    r = kubectl(*args)
    return r.stdout.strip() if r.returncode == 0 else None

def claims(jwt):
    return json.loads(base64.urlsafe_b64decode(jwt.split(".")[1] + "==="))

def header(jwt):
    return json.loads(base64.urlsafe_b64decode(jwt.split(".")[0] + "==="))

@contextlib.contextmanager
def forward(target, ns, local, remote):
    p = subprocess.Popen(["kubectl", "-n", ns, "port-forward", target, "%d:%d" % (local, remote)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(60):
            with contextlib.suppress(OSError):
                socket.create_connection(("127.0.0.1", local), timeout=1).close()
                break
            time.sleep(0.5)
        yield
    finally:
        p.terminate()

# A credential as a thief who had the MCP server's pod would get one: from
# inside it, by its own token for Vault's audience. Printed to this process
# only, never shown.
MINT = r'''
import sys; sys.path.insert(0, "/app"); import server
with open(server.VAULT_TOKEN_FILE) as f:
    sa = f.read().strip()
try:
    login = server._vault("POST", "auth/kubernetes/login", {"role": server.VAULT_ROLE, "jwt": sa})
    print(server._vault("GET", "identity/oidc/token/" + sys.argv[1], token=login["auth"]["client_token"])["data"]["token"])
except (server.NoCredential, KeyError, TypeError):
    print("REFUSED")
'''
def mint(role="records-api"):
    r = kubectl("-n", "mcp", "exec", "deploy/mcp-server", "--", "python3", "-c", MINT, role)
    out = r.stdout.strip()
    return out if r.returncode == 0 and out.count(".") == 2 else None

def records(path, bearer=None, method="GET"):
    h = {"Accept": "application/json"}
    if bearer is not None:
        h["Authorization"] = "Bearer " + bearer
    req = urllib.request.Request("http://127.0.0.1:18083" + path, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status
    except urllib.error.HTTPError as e:
        e.close()
        return e.code

agent = token("agents", "support-agent", "mcp.boundary.heyvaldemar.com")
dana = token("people", "dana", "people.boundary.heyvaldemar.com")
def tool(name, args):
    p = {"name": name, "arguments": args, "_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
                                                    "io.modelcontextprotocol/clientCapabilities": {}}}
    h = {"Content-Type": "application/json", "Accept": "application/json", "MCP-Protocol-Version": "2026-07-28",
         "Mcp-Method": "tools/call", "Mcp-Name": name, "Authorization": "Bearer " + agent, "On-Behalf-Of": "Bearer " + dana}
    req = urllib.request.Request("http://127.0.0.1:18082/mcp", method="POST", headers=h,
                                 data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": p}).encode())
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            b = json.loads(r.read())
    except (urllib.error.URLError, OSError, ValueError) as e:
        return "no answer: " + type(e).__name__
    return " ".join(c.get("text", "") for c in b.get("result", {}).get("content", [])) or json.dumps(b.get("error"))

def record_ok():
    return "Northwind" in tool("records_lookup", {"customer_id": "C1001"})

def records_log():
    # The newest pod: one restarted just before may still be stopping.
    pod = kubectl("-n", "corp", "get", "pod", "-l", "app.kubernetes.io/name=records-api",
                  "--sort-by=.metadata.creationTimestamp", "-o", "name").stdout.split()[-1]
    lines = kubectl("-n", "corp", "logs", pod, "--since-time=" + since).stdout.splitlines()
    return [json.loads(l) for l in lines if l.startswith("{")]

op = open(os.path.join(V.STATE, "operator.token")).read().strip()
def vault(method, path, body=None, tok=op):
    return V.call(method, path, body, tok)

with forward("svc/mcp-server", "mcp", 18082, 8080), forward("svc/records-api", "corp", 18083, 8080), V.forward():
    step("1. what Kubernetes gives on its own")
    short = kubectl("-n", "mcp", "create", "token", "mcp-server", "--audience", "records-api", "--duration", "1m")
    check(short.returncode != 0 and "10 minutes" in short.stderr,
          "the API server refuses a token shorter than ten minutes: %s" % short.stderr.strip().split(": ")[-1][:80])
    k8s_records = token("agents", "support-agent", "records-api")
    check(k8s_records is not None and claims(k8s_records).get("aud") == ["records-api"],
          "any service account gets a token for the audience records-api from the cluster: the agent's did")
    measure("Kubernetes' shortest token: 600 s; the agent's service account was issued one for records-api")

    step("2. the records tool, through Vault's credential, and no records key")
    check(record_ok(), "control: acting for Dana, the MCP server reads C1001 from the records service with Vault's credential")
    calls = [l for l in records_log() if l.get("path") == "/records/C1001" and l.get("status") == 200]
    check(calls and all(c.get("service_account") == "mcp/mcp-server" and c.get("sub") for c in calls),
          "the records service logs who called: %s" % (calls[-1].get("service_account") if calls else "nothing"))
    names = kubectl("get", "secrets", "-A", "-o", "jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}").stdout.split()
    vols = json.loads(kubectl("get", "pods", "-n", "corp", "-l", "app.kubernetes.io/name=records-api", "-o", "json").stdout)["items"] + \
        json.loads(kubectl("get", "pods", "-n", "mcp", "-l", "app.kubernetes.io/name=mcp-server", "-o", "json").stdout)["items"]
    mounted = [v["secret"]["secretName"] for p in vols for v in p["spec"].get("volumes", []) if "secret" in v]
    envs = [e for p in vols for c in p["spec"]["containers"] for e in c.get("env", []) if "valueFrom" in e]
    check("records-api-key" not in names and vols and not mounted and not envs,
          "no records key: no Secret records-api-key, and no Secret mounted in or read by the records service or the MCP server (%d pods)" % len(vols))

    step("3. the credential")
    cred = mint()
    c = claims(cred) if cred else {}
    life = c.get("exp", 0) - c.get("iat", 0)
    check(cred and header(cred).get("alg") == "RS256" and c.get("iss") == setup["oidc_issuer"] + "/v1/identity/oidc"
          and c.get("aud") == "records-api" and c.get("scope") == "records:read outbox:send"
          and c.get("k8s_service_account") == "mcp-server" and c.get("k8s_namespace") == "mcp",
          "Vault's credential: RS256, its issuer, audience records-api, scope records:read outbox:send, for mcp/mcp-server")
    check(0 < life <= LIMIT, "the credential lives %d s, at most the records service's limit of %d s" % (life, LIMIT))
    measure("records credential lifetime: before, no expiry (the key lived as long as the cluster); after, %d s" % life)
    check(records("/records/C1001", cred) == 200, "control: the records service takes the credential for GET /records/C1001")
    expired = cred

    step("4. who may get a credential")
    def login(jwt):
        return vault("POST", "auth/kubernetes/login", {"role": "mcp-server", "jwt": jwt or "x"}, None)[0]
    check(login(token("mcp", "mcp-server", VAULT_AUD)) == 200,
          "control: Vault takes the MCP server's token for its audience")
    for who, jwt in (("the agent's service account, for Vault's audience", token("agents", "support-agent", VAULT_AUD)),
                     ("another service account in the MCP server's namespace", token("mcp", "default", VAULT_AUD)),
                     ("the MCP server's own token for the Kubernetes API", token("mcp", "mcp-server"))):
        st = login(jwt)
        check(st in (400, 403), "Vault refuses a login by %s (HTTP %d)" % (who, st))
    def connect(target):
        r = kubectl("-n", "agents", "exec", "vault-probe", "--", "python3", "-c",
                    "import socket,sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), 4); print('open')", *target)
        return "open" in r.stdout
    check(connect(("mcp-server.mcp.svc.cluster.local", "8080")), "control: an agent pod connects to the MCP server")
    check(not connect(("vault.vault.svc.cluster.local", "8200")), "an agent pod cannot connect to Vault")
    r = kubectl("-n", "corp", "exec", "deploy/records-api", "--", "python3", "-c",
                "import socket; socket.create_connection(('vault.vault.svc.cluster.local', 8200), 4); print('open')")
    check("open" not in r.stdout, "the records service cannot connect to Vault: it calls nobody")

    step("5. what the records service refuses")
    check(records("/records/C1001") == 401, "no credential: 401")
    check(records("/records/C1001", secrets.token_urlsafe(32)) == 401, "a random key, the old kind of credential: 401")
    check(records("/records/C1001", k8s_records) == 401, "the cluster's own token for the audience records-api: 401")
    fresh = mint()
    check(records("/records/C1001", fresh, "DELETE") == 403 and records("/records/C1001", fresh) == 200,
          "a delete with a valid credential: 403, no role issues records:delete, and the record is still there")
    # A role for another audience on the same key, planted and removed.
    key0 = vault("GET", "identity/oidc/key/records")[1]["data"]
    pol0 = vault("GET", "sys/policies/acl/records-caller")[1]["data"]["policy"]
    vault("POST", "identity/oidc/key/records", dict(key0, allowed_client_ids=key0["allowed_client_ids"] + ["reports-api"]))
    role0 = vault("GET", "identity/oidc/role/records-api")[1]["data"]
    vault("POST", "identity/oidc/role/plant-wrong-audience", {"key": "records", "client_id": "reports-api", "ttl": "60s",
                                                             "template": role0["template"]})
    vault("PUT", "sys/policies/acl/records-caller", {"policy": pol0 + '\npath "identity/oidc/token/plant-wrong-audience" {\n  capabilities = ["read"]\n}\n'})
    other = mint("plant-wrong-audience")
    check(other and claims(other).get("aud") == "reports-api" and header(other).get("kid") in [k["kid"] for k in V.call("GET", "identity/oidc/.well-known/keys")[1]["keys"]],
          "plant: Vault issued a credential for the audience reports-api, signed by the records key")
    check(other and records("/records/C1001", other) == 401, "a credential for another audience, signed by Vault's own key: 401")
    vault("DELETE", "identity/oidc/role/plant-wrong-audience")
    vault("POST", "identity/oidc/key/records", key0)
    vault("PUT", "sys/policies/acl/records-caller", {"policy": pol0})
    put_back = vault("GET", "identity/oidc/key/records")[1]["data"]["allowed_client_ids"] == ["records-api"] and \
        vault("GET", "sys/policies/acl/records-caller")[1]["data"]["policy"] == open(os.path.join(root, "manifests", "vault", "records-caller.hcl")).read() and \
        mint("plant-wrong-audience") is None
    check(put_back, "the plant removed: the key signs for records-api alone, the policy is the file's, and the role is gone")
    # Vault's TTL raised to an hour, planted and put back.
    vault("POST", "identity/oidc/role/records-api", dict(role0, ttl="3600s"))
    long = mint()
    check(long and claims(long)["exp"] - claims(long)["iat"] == 3600, "plant: with Vault's TTL raised, it issued a credential for 3600 s")
    check(long and records("/records/C1001", long) == 401, "a credential that lives longer than %d s, though Vault issued it: 401" % LIMIT)
    vault("POST", "identity/oidc/role/records-api", role0)
    again = mint()
    check(again and claims(again)["exp"] - claims(again)["iat"] == LIMIT and records("/records/C1001", again) == 200,
          "the TTL put back: a new credential lives %d s and is taken" % LIMIT)
    wait = claims(expired)["exp"] + 1 - time.time()
    if wait > 0:
        time.sleep(wait)
    check(records("/records/C1001", expired) == 401, "the first credential, once expired: 401")
    reasons = {l.get("refused") for l in records_log() if l.get("refused")}
    want = {"no credential", "not a JWT", "signature not by Vault's key", "wrong audience", "lives longer than %d s" % LIMIT, "expired", "no scope records:delete"}
    check(want <= reasons, "the records service's log gives each reason: %s" % ", ".join(sorted(reasons & want)))

    step("6. Vault's image, carried or not")
    def admitted(image):
        pod = {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "plant-vault-image", "namespace": "vault"},
               "spec": {"automountServiceAccountToken": False,
                        "securityContext": {"runAsNonRoot": True, "runAsUser": 100, "seccompProfile": {"type": "RuntimeDefault"}},
                        "containers": [{"name": "vault", "image": image, "command": ["vault", "version"],
                                        "securityContext": {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}}}]}}
        r = kubectl("create", "--dry-run=server", "-f", "-", stdin=json.dumps(pod))
        return r.returncode == 0, r.stderr.strip()
    ok, _ = admitted(vault_image)
    check(ok, "control: a pod with the Vault image the bundle carried is admitted (server dry run)")
    ok, why = admitted(uncarried)
    check(not ok and "carried" in why, "a pod with a Vault image the bundle did not carry (2.2.0) is refused at admission")

    step("7. revocation: the MCP server's identity disabled in Vault, %d rounds" % rounds)
    entity = claims(again)["sub"]
    cut, copied, stopped, back, other_ok = [], [], [], [], True
    for n in range(1, rounds + 1):
        # Each round starts at a different point in the MCP server's own
        # credential's life, so its records tool stops after a different wait.
        time.sleep(random.uniform(0, 20))
        if not record_ok():
            check(False, "round %d: the records tool did not answer before the cut-off" % n)
            break
        copy = mint()
        t0 = time.monotonic()
        vault("POST", "identity/entity/id/" + entity, {"disabled": True})
        seen = {}
        def watch(name, failed, every):
            while time.monotonic() - t0 < 90 and name not in seen:
                if failed():
                    seen[name] = time.monotonic() - t0
                time.sleep(every)
        jobs = [threading.Thread(target=watch, args=a) for a in (
            ("vault", lambda: login(token("mcp", "mcp-server", VAULT_AUD)) != 200, 0.2),
            ("copy", lambda: records("/records/C1001", copy) == 401, 0.5),
            ("tool", lambda: not record_ok(), 1.0))]
        for j in jobs:
            j.start()
        time.sleep(3)
        other_ok = other_ok and "Q3" in tool("quarterly_report", {})
        for j in jobs:
            j.join()
        vault("POST", "identity/entity/id/" + entity, {"disabled": False})
        t1 = time.monotonic()
        while time.monotonic() - t1 < 60 and not record_ok():
            time.sleep(1)
        b = time.monotonic() - t1
        print("  round %d: Vault refused a new credential after %s s, the copy's first 401 after %s s, the records tool stopped after %s s, back %.1f s after it was enabled"
              % (n, *["%.1f" % seen[k] if k in seen else "never" for k in ("vault", "copy", "tool")], b), flush=True)
        if len(seen) < 3 or b >= 60:
            check(False, "round %d: not every effect of the cut-off was seen within 90 s, or the tool was not back within 60 s" % n)
            break
        cut.append(seen["vault"]); copied.append(seen["copy"]); stopped.append(seen["tool"]); back.append(b)
    if len(cut) == rounds:
        check(max(cut) < 2, "Vault refused a new credential within 2 s of the cut-off, every round (at most %.1f s)" % max(cut))
        check(max(copied) <= LIMIT + 2, "a credential copied just before the cut-off got its first 401 within its lifetime, every round (at most %.1f s)" % max(copied))
        check(max(stopped) <= LIMIT + 2, "the MCP server's records tool stopped within a credential's lifetime, every round (at most %.1f s)" % max(stopped))
        check(other_ok, "the MCP server's report tool answered while its records credential was cut off")
        def span(xs):
            return "median %.1f s, from %.1f to %.1f s over %d rounds" % (statistics.median(xs), min(xs), max(xs), len(xs))
        measure("revocation, Vault refuses a new credential: " + span(cut))
        measure("revocation, a credential copied just before: first 401 after " + span(copied))
        measure("revocation, the MCP server's records tool stops: " + span(stopped))
        measure("revocation undone, the records tool back: " + span(back))

    step("8. Vault's audit")
    audit = [json.loads(l) for l in kubectl("-n", "vault", "logs", "vault-0", "--since-time=" + since).stdout.splitlines()
             if l.startswith('{"') and '"type":"response"' in l]
    issued = [a for a in audit if a.get("request", {}).get("path") == "identity/oidc/token/records-api" and not a.get("error")]
    owners = {(a.get("auth", {}).get("metadata") or {}).get("service_account_namespace", "?") + "/" +
              (a.get("auth", {}).get("metadata") or {}).get("service_account_name", "?") for a in issued}
    refused = [a for a in audit if a.get("request", {}).get("path") == "auth/kubernetes/login" and a.get("error")]
    check(issued and owners == {"mcp/mcp-server"},
          "Vault's audit names the service account of every credential it issued: %d, all to %s" % (len(issued), ", ".join(sorted(owners))))
    check(len(refused) >= 3, "Vault's audit holds every login it refused: %d" % len(refused))

    step("9. what Vault costs")
    inst = json.load(open(os.path.join(V.STATE, "install.json")))
    measure("Vault install (scripts/vault.sh install), from its manifests applied to unsealed, configured and its keys written: %.1f s" % inst["seconds"])
    node = kubectl("-n", "vault", "get", "pod", "vault-0", "-o", "jsonpath={.spec.nodeName}").stdout
    stats = json.loads(kubectl("get", "--raw", "/api/v1/nodes/%s/proxy/stats/summary" % node).stdout or "{}")
    for p in stats.get("pods", []):
        if p["podRef"]["namespace"] == "vault" and p["podRef"]["name"] == "vault-0":
            ws = sum(cn.get("memory", {}).get("workingSetBytes", 0) for cn in p.get("containers", []))
            cpu = sum(cn.get("cpu", {}).get("usageCoreNanoSeconds", 0) for cn in p.get("containers", []))
            measure("Vault's pod after the drills: %.0f MiB of memory in use (request 128 MiB, limit 512 MiB), %.1f CPU seconds since it started"
                    % (ws / 2**20, cpu / 1e9))
    du = kubectl("-n", "vault", "exec", "vault-0", "--", "du", "-sk", "/vault/data").stdout.split()
    if du:
        measure("Vault's integrated storage after the drills: %d KiB on its 1 GiB volume" % int(du[0]))
    imgs = json.loads(kubectl("get", "node", node, "-o", "json").stdout)["status"].get("images", [])
    size = next((i["sizeBytes"] for i in imgs if any(vault_image.split("@")[1] in n for n in i.get("names", []))), None)
    if size:
        measure("Vault's image on the node: %.0f MB" % (size / 1e6))

if results:
    d = json.load(open(results)) if os.path.exists(results) else {"checks": [], "measured": []}
    d["checks"] += checks
    d.setdefault("measured", []).extend(measured)
    json.dump(d, open(results, "w"), indent=1)
print("\n%d checks: %d passed, %d failed" % (len(checks), sum(c["passed"] for c in checks), sum(not c["passed"] for c in checks)))
sys.exit(0 if checks and all(c["passed"] for c in checks) else 1)
PY
rc=$?
kubectl -n agents delete pod vault-probe --ignore-not-found --wait=false >/dev/null 2>&1
exit $rc
