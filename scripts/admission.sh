#!/usr/bin/env bash
# admission.sh <fetch|install|policy> - Kyverno inside the boundary.
#
#   fetch    download the chart admission/charts.lock pins and check its
#            sha256; runs before the boundary closes
#   install  install it from that file, its images pulled through the mirror
#            inside and the boundary's CA added to Kyverno's trust, so it can
#            read signatures from registry.boundary.internal over TLS
#   policy   apply admission/model-volumes.yaml (native) and
#            admission/verify-models.yaml with the operator's public key
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$ROOT/.cache/airgap"
say() { printf '== %s\n' "$*"; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
read -r _ VERSION REPO SHA < <(grep -E '^kyverno ' "$ROOT/admission/charts.lock")
CHART="$STATE/charts/kyverno-$VERSION.tgz"

render_policy() {
  python3 - "$ROOT/admission/verify-models.yaml" "$STATE/operator.pub" <<'PY'
import sys
policy, key = open(sys.argv[1]).read(), open(sys.argv[2]).read().strip()
print(policy.replace("@OPERATOR_KEY@", key.replace("\n", "\n            ")))
PY
}

case "${1:-}" in
  fetch)
    mkdir -p "$STATE/charts"
    helm pull kyverno --repo "$REPO" --version "$VERSION" -d "$STATE/charts" >/dev/null
    [ "$(sha256 "$CHART")" = "$SHA" ] || { echo "kyverno-$VERSION.tgz is not the archive charts.lock pins" >&2; exit 1; }
    say "kyverno chart $VERSION fetched and checked"
    ;;
  install)
    helm upgrade --install kyverno "$CHART" --namespace kyverno --create-namespace --wait --timeout 10m \
      -f "$ROOT/admission/kyverno-images.yaml" -f "$ROOT/admission/kyverno-values.yaml" \
      --set-file "global.caCertificates.data=$STATE/ca.crt" >/dev/null
    kubectl -n kyverno rollout status deployment/kyverno-admission-controller --timeout=300s >/dev/null
    # Rolled out is not serving: wait until a server-side dry run of the
    # policy goes through the webhook that validates policies.
    for _ in $(seq 1 60); do
      render_policy | kubectl apply --dry-run=server -f - >/dev/null 2>&1 && { say "kyverno $VERSION is up, installed from inside"; exit 0; }
      sleep 5
    done
    render_policy | kubectl apply --dry-run=server -f -
    exit 1
    ;;
  policy)
    kubectl apply -f "$ROOT/admission/model-volumes.yaml" >/dev/null
    render_policy | kubectl apply -f - >/dev/null
    for _ in $(seq 1 60); do
      [ "$(kubectl get imagevalidatingpolicy verify-models -o jsonpath='{.status.conditionStatus.ready}' 2>/dev/null)" = true ] && break
      sleep 2
    done
    say "model-volumes and verify-models applied, the latter with the operator's key"
    ;;
  *) echo "usage: admission.sh <fetch|install|policy>" >&2; exit 2 ;;
esac
