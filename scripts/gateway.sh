#!/usr/bin/env bash
# gateway.sh <fetch|install|route> - the inference gateway in front of the model
# servers: agentgateway, with the Gateway API, pinned by gateway/gateway.lock.
#
#   fetch    outside, connected: the Gateway API CRDs and both charts, each
#            refused unless its sha256 is the one gateway.lock pins; they go
#            where the bundle takes charts from, and cross with everything
#            else
#   install  inside: the CRDs, the charts with the images by digest,
#            manifests/gateway/gateway.yaml with the cluster's service account
#            issuer and public keys written in, and one route.yaml for each
#            model served: SERVED lists them as model=Service pairs, and
#            defaults to $MODEL=llama, the one server the evals use; set and
#            empty, no model is served inside (the frontier job's route is
#            scripts/frontier.sh's); waits until the Gateway is programmed
#            and its proxy answers
#   route    one route.yaml more for each model=Service pair given, on a
#            gateway already installed: a second model served later in the
#            run (ADR 19)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$ROOT/.cache/airgap"
# shellcheck source=scripts/inside.sh
. "$ROOT/scripts/inside.sh"
DIR="$STATE/charts"
LOCK="$ROOT/gateway/gateway.lock"
say() { printf '== %s\n' "$*"; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
lock() { awk -v k="$1" -v n="$2" '$1 == k && $2 == n {print $'"$3"'}' "$LOCK"; }
crds_file() { echo "$DIR/gateway-api-standard-$(lock crds gateway-api 3).yaml"; }
chart_file() { echo "$DIR/$1-$(lock chart "$1" 3).tgz"; }
routes() {
  for pair in "$@"; do
    sed -e "s#@MODEL@#${pair%%=*}#g" -e "s#@SERVICE@#${pair#*=}#g" "$ROOT/manifests/gateway/route.yaml" \
      | kubectl apply -f - >/dev/null
  done
}
# The tag and digest of an image in the lock: everything after the first
# colon, which is the tag's (the registry has no port).
tag_of() { local ref; ref="$(lock image "$1" 4)"; echo "${ref#*:}"; }

case "${1:-}" in
  fetch)
    mkdir -p "$DIR"
    curl -fsSL -o "$(crds_file)" "$(lock crds gateway-api 5)"
    [ "$(sha256 "$(crds_file)")" = "$(lock crds gateway-api 4)" ] || { echo "the Gateway API CRDs are not the file gateway.lock pins" >&2; exit 1; }
    for chart in agentgateway-crds agentgateway; do
      helm pull "$(lock chart "$chart" 5)" --version "$(lock chart "$chart" 3)" -d "$DIR" >/dev/null 2>&1
      [ "$(sha256 "$(chart_file "$chart")")" = "$(lock chart "$chart" 4)" ] || { echo "$chart is not the chart gateway.lock pins" >&2; exit 1; }
    done
    say "the Gateway API CRDs and the agentgateway charts fetched and checked against gateway/gateway.lock"
    ;;
  install)
    # Server-side: the standard CRDs are larger than a client-side apply's
    # last-applied annotation may be.
    kubectl apply --server-side -f "$(crds_file)" >/dev/null
    helm upgrade --install agentgateway-crds "$(chart_file agentgateway-crds)" \
      --namespace agentgateway-system --create-namespace --wait >/dev/null
    # The images by digest, from the lock: the chart writes the tag as given,
    # so tag@digest is what the controller's pod and the proxy it starts run.
    # Under INSIDE when it is set, where the registry inside is not a mirror.
    registry=(); [ -z "${INSIDE:-}" ] || registry=(--set "image.registry=$(relocated cr.agentgateway.dev)")
    # GATEWAY_REPLICAS (ADR 20): the controller too, spread over the nodes,
    # with a budget. With one controller on a node that was lost, the proxy
    # left on the other node learned of no endpoint change and sent a share
    # of the requests to a model server that was gone, 503 to the end of the
    # window (run 40109411614).
    controller=()
    if [ -n "${GATEWAY_REPLICAS:-}" ]; then
      controller=(--set "controller.replicaCount=$GATEWAY_REPLICAS"
        --set-json 'controller.podDisruptionBudget={"minAvailable":1}'
        --set-json 'topologySpreadConstraints=[{"maxSkew":1,"topologyKey":"kubernetes.io/hostname","whenUnsatisfiable":"ScheduleAnyway","labelSelector":{"matchLabels":{"app.kubernetes.io/name":"agentgateway"}}}]')
    fi
    helm upgrade --install agentgateway "$(chart_file agentgateway)" \
      --namespace agentgateway-system --wait --timeout 5m "${registry[@]}" "${controller[@]}" \
      --set "controller.image.tag=$(tag_of controller)" --set "proxy.image.tag=$(tag_of proxy)" >/dev/null
    # The cluster's service account issuer and its public keys, read once
    # from the API server: the gateway checks a token against them with
    # nothing to fetch at request time.
    mkdir -p "$STATE"
    kubectl get --raw /.well-known/openid-configuration >"$STATE/cluster-oidc.json"
    kubectl get --raw /openid/v1/jwks >"$STATE/cluster-jwks.json"
    # GATEWAY_REPLICAS: more than one proxy, spread over the nodes (ADR 20).
    python3 - "$ROOT/manifests/gateway/gateway.yaml" "$STATE/cluster-oidc.json" "$STATE/cluster-jwks.json" "${GATEWAY_REPLICAS:-}" <<'PY' | kubectl apply -f - >/dev/null
import json, sys
text, oidc, jwks = (open(f).read() for f in sys.argv[1:4])
replicas = sys.argv[4]
if replicas:
    text = text.replace("""  deployment:
    spec:
      template:
        spec:
""", """  deployment:
    spec:
      replicas: %s
      template:
        spec:
          topologySpreadConstraints:
            - maxSkew: 1
              topologyKey: kubernetes.io/hostname
              whenUnsatisfiable: ScheduleAnyway
              labelSelector:
                matchLabels: {gateway.networking.k8s.io/gateway-name: models}
""" % int(replicas), 1)
print(text.replace("@ISSUER@", json.loads(oidc)["issuer"])
          .replace("@JWKS@", json.dumps(json.loads(jwks), separators=(",", ":"))))
PY
    served="${SERVED-${MODEL:?MODEL or SERVED names the models the gateway routes}=llama}"
    # shellcheck disable=SC2086 # one word a pair
    routes $served
    # The gateway is the one way in: the agents' own rule to the model
    # servers goes, and their default-deny leaves them the gateway alone.
    kubectl -n agents delete networkpolicy allow-model --ignore-not-found >/dev/null
    kubectl -n gateway wait gateway/models --for=condition=Programmed --timeout=180s >/dev/null
    for _ in $(seq 1 60); do
      kubectl -n gateway get deploy -o name 2>/dev/null | grep -q . && break
      sleep 2
    done
    kubectl -n gateway rollout status deploy --timeout=180s >/dev/null
    say "agentgateway is up inside: Gateway models programmed, routes for ${served:-no model inside}, a quota and a token budget per service account"
    ;;
  route)
    shift
    [ "$#" -gt 0 ] || { echo "usage: gateway.sh route <model=Service>..." >&2; exit 2; }
    routes "$@"
    say "the gateway routes $* too"
    ;;
  *)
    echo "usage: gateway.sh <fetch|install|route>" >&2
    exit 2
    ;;
esac
