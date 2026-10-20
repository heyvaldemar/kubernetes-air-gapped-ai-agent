#!/usr/bin/env bash
# frontier.sh <open|token|refresh|close> - one way out of a closed boundary,
# for a model that runs outside it (ADR 14). Runs after scripts/airgap.sh
# close and scripts/gateway.sh install, on a cluster made from
# kind/frontier.yaml.
#
#   open     the host's firewall lets the egress node, and nothing else on
#            kind's network, open TCP 443 to Anthropic's published API range;
#            the API server refuses any pod but the gateway's a place there
#            (admission/egress-node.yaml); the gateway's proxy moves there,
#            with the API's address written in, and its route for $MODEL
#            leads to the API (manifests/gateway/frontier.yaml)
#   token    exchange the runner's GitHub identity for a ten-minute API token
#            and hand it to the gateway as the Secret inference/anthropic-token,
#            through kubectl's stdin: it is never an argument, a file or a log
#            line. Prints only how long it lives and how long it is
#   refresh  token, every $REFRESH_SECONDS (default 240), until killed
#   close    take the firewall rule out again
#
# No API key exists anywhere. Anthropic exchanges the runner's OIDC token
# under a federation rule that names this repository's main branch and
# nothing else, for a service account in a workspace with its own spend
# limit. The ids below name that rule; without a token GitHub signed for a
# run on main, they open nothing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# https://platform.claude.com/docs/en/api/ip-addresses, read 2026-10-20:
# "fixed IP addresses ... will not change without notice". IPv4 only: the
# cluster is IPv4 only and the ip6tables rule stays closed.
RANGE=160.79.104.0/23
EGRESS_LABEL=boundary.heyvaldemar.com/egress=anthropic
FEDERATION_RULE=fdrl_019tLYZWjkgGsVCfpCqN9ijM
ORGANIZATION=5b81a33e-20db-4174-a4f6-b2b4a2ee5e4d
SERVICE_ACCOUNT=svac_01PEL3wPWkX9sUr9A335iPA2
WORKSPACE=wrkspc_01URiMzLzWZWaonHTZfCsjsb
say() { printf '== %s\n' "$*"; }

egress_node() { kubectl get nodes -l "$EGRESS_LABEL" -o jsonpath='{.items[0].metadata.name}'; }
node_ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
bridge() { echo "br-$(docker network inspect kind -f '{{.Id}}' | cut -c1-12)"; }
rule() { echo "-i $(bridge) ! -o $(bridge) -s $(node_ip "$(egress_node)") -d $RANGE -p tcp --dport 443 -j ACCEPT"; }

case "${1:-}" in
  open)
    [ "$(uname -s)" = Linux ] || { echo "open needs the host's iptables: Linux only" >&2; exit 1; }
    node="$(egress_node)"
    [ -n "$node" ] || { echo "no node labelled $EGRESS_LABEL: make the cluster from kind/frontier.yaml" >&2; exit 1; }
    # The API's address, resolved here, outside, and refused unless it is in
    # the range the firewall opens: a name that moved would otherwise send
    # the gateway at an address the rule does not cover, or one it should not.
    ip="$(getent ahostsv4 api.anthropic.com | awk 'NR == 1 {print $1}')"
    python3 -c 'import ipaddress, sys; sys.exit(ipaddress.ip_address(sys.argv[1]) not in ipaddress.ip_network(sys.argv[2]))' "$ip" "$RANGE" \
      || { echo "api.anthropic.com resolved to ${ip:-nothing}, outside $RANGE" >&2; exit 1; }
    # Before the bridge's REJECT (airgap.sh close), so it is the one exception.
    # shellcheck disable=SC2046
    sudo iptables -C DOCKER-USER $(rule) 2>/dev/null || sudo iptables -I DOCKER-USER 1 $(rule)
    kubectl apply -f "$ROOT/admission/egress-node.yaml" >/dev/null
    # The policy is enforced once the API server has read it; until then a
    # plant would be admitted and the check would say so, not this script.
    sed -e "s#@MODEL@#${MODEL:?MODEL names the model the agent asks for}#g" -e "s#@API_IP@#$ip#g" \
      "$ROOT/manifests/gateway/frontier.yaml" | kubectl apply -f - >/dev/null
    # The controller rewrites the proxy's Deployment after it reads the new
    # parameters, so a rollout check alone can pass on the old one.
    for _ in $(seq 1 90); do
      [ "$(kubectl -n gateway get pods --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u)" = "$node" ] && break
      sleep 2
    done
    kubectl -n gateway rollout status deploy --timeout=180s >/dev/null
    say "one way out: $node ($(node_ip "$node")) to $RANGE on TCP 443, nothing else on kind's network; the gateway runs there and routes $MODEL to api.anthropic.com ($ip)"
    ;;
  token)
    : "${ACTIONS_ID_TOKEN_REQUEST_URL:?a GitHub Actions job with id-token: write mints the identity this exchanges}"
    FEDERATION_RULE="$FEDERATION_RULE" ORGANIZATION="$ORGANIZATION" SERVICE_ACCOUNT="$SERVICE_ACCOUNT" WORKSPACE="$WORKSPACE" \
      python3 - <<'PY' | kubectl apply -f - >/dev/null
import json, os, re, sys, urllib.error, urllib.parse, urllib.request

def redacted(text):
    # A key, or a JWT (the runner's own identity token is one).
    text = re.sub(r"sk-ant-[A-Za-z0-9_-]+", "<redacted>", str(text))
    return re.sub(r"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_.-]+", "<redacted>", text)[:300]

# The runner's identity: a JWT GitHub signs for this job, for Anthropic's
# audience, valid about five minutes and good for one exchange.
req = urllib.request.Request(
    os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"] + "&audience=" + urllib.parse.quote("https://api.anthropic.com", safe=""),
    headers={"Authorization": "bearer " + os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]})
with urllib.request.urlopen(req, timeout=30) as r:
    jwt = json.load(r)["value"]
body = json.dumps({"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": jwt,
                   "federation_rule_id": os.environ["FEDERATION_RULE"], "organization_id": os.environ["ORGANIZATION"],
                   "service_account_id": os.environ["SERVICE_ACCOUNT"], "workspace_id": os.environ["WORKSPACE"]}).encode()
req = urllib.request.Request("https://api.anthropic.com/v1/oauth/token", data=body, method="POST", headers={
    "Content-Type": "application/json", "anthropic-beta": "oauth-2025-04-20,oidc-federation-2026-04-01"})
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.load(r)
except urllib.error.HTTPError as e:
    # The status, the error's name and its message, never the body as it
    # came: some servers echo what they refused, so anything shaped like a
    # key or a JWT is taken out first.
    try:
        err = json.loads(e.read())
        if isinstance(err.get("error"), str):  # OAuth's shape
            why = "%s: %s" % (err["error"], err.get("error_description", ""))
        else:                                  # the API's shape
            why = "%s: %s" % ((err.get("error") or {}).get("type"), (err.get("error") or {}).get("message", ""))
    except ValueError:
        why = "no JSON in the answer"
    sys.exit("the token exchange was refused: HTTP %d, %s (request %s)" % (e.code, redacted(why), e.headers.get("request-id", "?")))
token, ttl = d["access_token"], int(d["expires_in"])
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                  "metadata": {"name": "anthropic-token", "namespace": "inference"},
                  "stringData": {"Authorization": token}}))
print("== the gateway holds a new API token: lives %d s, %d characters" % (ttl, len(token)), file=sys.stderr)
PY
    ;;
  refresh)
    while sleep "${REFRESH_SECONDS:-240}"; do
      "$0" token || echo "== the token was not replaced; the one the gateway holds lives on until it expires" >&2
    done
    ;;
  close)
    # shellcheck disable=SC2046
    sudo iptables -D DOCKER-USER $(rule) 2>/dev/null || true
    say "the one way out is closed"
    ;;
  *)
    echo "usage: frontier.sh <open|token|refresh|close>" >&2
    exit 2
    ;;
esac
