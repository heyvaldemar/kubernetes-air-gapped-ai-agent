#!/usr/bin/env bash
# tests/e2e/people.sh - prove that the agent acts for a person, with that
# person's rights and no more (ADR 15), against the MCP server as it runs,
# with real tokens and no model. Each refusal sits beside a call that must
# succeed from the same place.
#
#   1. the agent acting for the support team's lead is listed every tool it
#      is granted (the control)
#   2. the agent alone, naming no person, is refused; so is a person's token
#      shown as the agent's, a token for the people audience from someone
#      policy.json does not know, and a person's token for the wrong audience
#   3. acting for first-line support, the agent is listed the records tool
#      alone, and a call to send_email is refused as if the tool did not exist
#   4. acting for an account manager, the agent reads her own customer's
#      record (the control) and is answered "not found" for another manager's
#   5. the MCP server's audit names the person every call was made for, and
#      records each refused for naming no one it knows
#
# One process mints the tokens with kubectl, keeps them in memory and makes
# the calls: no token is an argument, a file or a log line. Appends to
# $E2E_RESULTS (JSON) when set.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PORT=18081
kubectl -n mcp port-forward svc/mcp-server "$PORT:8080" >/dev/null 2>&1 &
forward=$!
trap 'kill $forward 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -fsS -m 2 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break; sleep 1; done

python3 - "$ROOT/manifests/mcp/policy.json" "$PORT" "${E2E_RESULTS:-}" <<'PY'
import json, os, subprocess, sys, time, urllib.error, urllib.request
policy_path, port, results = sys.argv[1], sys.argv[2], sys.argv[3]
policy = json.load(open(policy_path))
since = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

def token(ns, sa, audience):
    return subprocess.run(["kubectl", "-n", ns, "create", "token", sa, "--audience", audience, "--duration", "10m"],
                          check=True, capture_output=True, text=True).stdout.strip()

people = policy["people_audience"]
tok = {
    "agent": token("agents", "support-agent", policy["audience"]),
    "lead": token("people", "support-lead", people),
    "dana": token("people", "dana", people),
    "sam": token("people", "sam", people),
    # A person's token for the MCP server's audience, and a token for the
    # people audience from a ServiceAccount that is no one's.
    "sam_wrong_audience": token("people", "sam", policy["audience"]),
    "stranger": token("agents", "support-agent", people),
}
URL = "http://127.0.0.1:%s/mcp" % port
PROTOCOL = "2026-07-28"
ids = iter(range(1, 1000))
checks = []

def rpc(method, params=None, bearer=None, behalf=None):
    p = dict(params or {})
    p["_meta"] = {"io.modelcontextprotocol/protocolVersion": PROTOCOL,
                  "io.modelcontextprotocol/clientCapabilities": {}}
    h = {"Content-Type": "application/json", "Accept": "application/json", "MCP-Protocol-Version": PROTOCOL,
         "Mcp-Method": method}
    if method == "tools/call":
        h["Mcp-Name"] = p["name"]
    if bearer:
        h["Authorization"] = "Bearer " + bearer
    if behalf:
        h["On-Behalf-Of"] = "Bearer " + behalf
    req = urllib.request.Request(URL, data=json.dumps({"jsonrpc": "2.0", "id": next(ids), "method": method,
                                                      "params": p}).encode(), method="POST", headers=h)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        with e:
            raw = e.read()
        return e.code, (json.loads(raw) if raw else None)

def listed(behalf):
    status, body = rpc("tools/list", bearer=tok["agent"], behalf=behalf)
    return sorted(t["name"] for t in (body or {}).get("result", {}).get("tools", [])) if status == 200 else "HTTP %d" % status

def text(status, body):
    if body and "result" in body:
        return " ".join(c.get("text", "") for c in body["result"].get("content", []))
    if body and "error" in body:
        return "error: " + body["error"].get("message", "")
    return "HTTP %d" % status

def check(ok, line):
    checks.append({"name": line, "passed": bool(ok)})
    print(("  PASS  " if ok else "  FAIL  ") + line, flush=True)

lead = listed(tok["lead"])
check(lead == ["quarterly_report", "records_lookup", "send_email"],
      "control: acting for the support team's lead, the agent is listed every tool it is granted: %s" % lead)
status, _ = rpc("tools/list", bearer=tok["agent"])
check(status == 403, "the agent alone, naming no person, is refused (HTTP %d)" % status)
status, _ = rpc("tools/list", bearer=tok["sam"], behalf=tok["sam"])
check(status == 401, "a person's token shown as the agent's is refused (HTTP %d)" % status)
status, _ = rpc("tools/list", bearer=tok["agent"], behalf=tok["stranger"])
check(status == 403, "a token for the people audience from someone policy.json does not know is refused (HTTP %d)" % status)
status, _ = rpc("tools/list", bearer=tok["agent"], behalf=tok["sam_wrong_audience"])
check(status == 403, "a person's token for the MCP server's audience, not the people one, is refused (HTTP %d)" % status)
sam = listed(tok["sam"])
check(sam == ["records_lookup"], "acting for first-line support, the agent is listed the records tool alone: %s" % sam)
said = text(*rpc("tools/call", {"name": "send_email", "arguments": {"to": "dana@acme.example", "subject": "s", "body": "b"}},
                 bearer=tok["agent"], behalf=tok["sam"]))
check(said.startswith("error: Unknown tool"),
      "acting for first-line support, send_email is refused as if it did not exist: %s" % said[:40])
own = text(*rpc("tools/call", {"name": "records_lookup", "arguments": {"customer_id": "C1001"}},
                bearer=tok["agent"], behalf=tok["dana"]))
check("Northwind" in own, "control: acting for Dana, the agent reads her own customer C1001")
other = text(*rpc("tools/call", {"name": "records_lookup", "arguments": {"customer_id": "C1090"}},
                  bearer=tok["agent"], behalf=tok["dana"]))
check(other == "The service answered HTTP 404.",
      "acting for Dana, another manager's customer C1090 is answered as one that does not exist: %s" % other[:40])

# The audit: every call above that got past the agent's own identity check
# names the person it was made for, or is a refusal for naming no one.
logs = subprocess.run(["kubectl", "-n", "mcp", "logs", "deploy/mcp-server", "--since-time=" + since],
                      capture_output=True, text=True).stdout.splitlines()
lines = [json.loads(l) for l in logs if l.startswith("{")]
calls = [a for a in lines if a.get("method", "").startswith("tools/") and a.get("decision") != "unauthenticated"]
named = [a for a in calls if a.get("on_behalf_of", "").startswith("system:serviceaccount:people:")]
nobody = [a for a in calls if a.get("decision") == "no_person"]
check(len(calls) == 8 and len(named) == 5 and len(nobody) == 3,
      "the MCP server's audit names the person each of %d calls was made for, and records %d refused for naming no one it knows"
      % (len(named), len(nobody)))

if results:
    d = json.load(open(results)) if os.path.exists(results) else {"checks": [], "measured": []}
    d["checks"] += checks
    json.dump(d, open(results, "w"), indent=1)
sys.exit(0 if checks and all(c["passed"] for c in checks) else 1)
PY
