#!/usr/bin/env bash
# tools.sh - the tool side, inside the boundary: the agent's namespace and
# identity, the MCP server, the records service and the report service, the
# network policies between them, a records key that only the records service
# and the MCP server hold, and the one path to the API server the MCP server
# needs for TokenReview. Adapted from kubernetes-ai-agent-sandbox's installer.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/inside.sh
. scripts/inside.sh
# The models' namespace, as the model server's manifest defines it: the
# model server's network policy lives there. scripts/serve.sh has made it
# when a model is served inside; the frontier job (ADR 14) serves none.
awk '/^---$/ {exit} {print}' manifests/inference/llama.yaml | kubectl apply -f - >/dev/null
kubectl kustomize manifests/ | relocate | kubectl apply -f - >/dev/null
if ! kubectl -n corp get secret records-api-key >/dev/null 2>&1 || ! kubectl -n mcp get secret records-api-key >/dev/null 2>&1; then
  python3 - <<'PY' | kubectl apply -f - >/dev/null
import json, secrets
key = secrets.token_urlsafe(32)
print(json.dumps({"apiVersion": "v1", "kind": "List", "items": [
    {"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
     "metadata": {"name": "records-api-key", "namespace": ns}, "stringData": {"key": key}}
    for ns in ("corp", "mcp")]}))
PY
fi
svc_ip="$(kubectl -n default get service kubernetes -o jsonpath='{.spec.clusterIP}')"
svc_port="$(kubectl -n default get service kubernetes -o jsonpath='{.spec.ports[0].port}')"
# Every address the API server answers on: one on kind, one per zone on EKS,
# whichever a connection to the Service's address is sent to.
ep_ips="$(kubectl -n default get endpointslices -l kubernetes.io/service-name=kubernetes -o jsonpath='{.items[*].endpoints[*].addresses[*]}')"
ep_port="$(kubectl -n default get endpointslices -l kubernetes.io/service-name=kubernetes -o jsonpath='{.items[0].ports[0].port}')"
python3 - "$svc_ip" "$svc_port" "$ep_ips" "$ep_port" <<'PY' | kubectl apply -f - >/dev/null
import json, sys
svc_ip, svc_port, ep_ips, ep_port = sys.argv[1:]
print(json.dumps({
    "apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy",
    "metadata": {"name": "mcp-server-to-api-server", "namespace": "mcp"},
    "spec": {"podSelector": {"matchLabels": {"app.kubernetes.io/name": "mcp-server"}},
             "policyTypes": ["Egress"],
             "egress": [{"to": [{"ipBlock": {"cidr": svc_ip + "/32"}}], "ports": [{"protocol": "TCP", "port": int(svc_port)}]},
                        {"to": [{"ipBlock": {"cidr": ip + "/32"}} for ip in ep_ips.split()], "ports": [{"protocol": "TCP", "port": int(ep_port)}]}]}}))
PY
# The document search's embedding model (ADR 21), served like the chat
# model: its signed image, admitted on its signature and AI-BOM.
SERVE_NAME=embed SERVE_MANIFEST=manifests/inference/embed.yaml MODEL=nomic-embed-text-v1.5 scripts/serve.sh
for d in tools/tool-gateway corp/records-api mcp/mcp-server; do
  kubectl -n "${d%/*}" rollout status "deployment/${d#*/}" --timeout=300s >/dev/null
done
printf '== the tool side is up: MCP server, records service, report service\n'
