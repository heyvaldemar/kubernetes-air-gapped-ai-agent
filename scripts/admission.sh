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
#
# With INSIDE set (scripts/inside.sh, the AWS run), Kyverno's images are named
# under it, the policies name its models path, and Kyverno reads signatures
# from ECR with the credential of its own AWS role (aws/admission.tf, through
# EKS Pod Identity): REGISTRY_CREDENTIALS names the provider, amazon.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$ROOT/.cache/airgap"
# shellcheck source=scripts/inside.sh
. "$ROOT/scripts/inside.sh"
say() { printf '== %s\n' "$*"; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
read -r _ VERSION REPO SHA < <(grep -E '^kyverno ' "$ROOT/admission/charts.lock")
CHART="$STATE/charts/kyverno-$VERSION.tgz"

render_policy() {
  python3 - "$ROOT/admission/verify-models.yaml" "$STATE/operator.pub" "$REG" "${REGISTRY_CREDENTIALS:-}" <<'PY'
import sys
policy, key = open(sys.argv[1]).read(), open(sys.argv[2]).read().strip()
reg, provider = sys.argv[3], sys.argv[4]
policy = policy.replace("@OPERATOR_KEY@", key.replace("\n", "\n            "))
policy = policy.replace("registry.boundary.internal:5000", reg)
if provider:
    policy = policy.replace("  validationActions: [Deny]\n",
                            "  validationActions: [Deny]\n  credentials:\n    providers: [%s]\n" % provider, 1)
print(policy)
PY
}
# model_volumes: admission/model-volumes.yaml, naming the models path inside
model_volumes() { sed "s#registry.boundary.internal:5000#$REG#g" "$ROOT/admission/model-volumes.yaml"; }
# kyverno_images: admission/kyverno-images.yaml, every image under INSIDE
kyverno_images() {
  if [ -z "${INSIDE:-}" ]; then cat "$ROOT/admission/kyverno-images.yaml"; return; fi
  sed -E "s#^([[:space:]]+registry:[[:space:]]*)([^[:space:]]+)#\1$INSIDE/\2#" "$ROOT/admission/kyverno-images.yaml"
}

case "${1:-}" in
  fetch)
    mkdir -p "$STATE/charts"
    helm pull kyverno --repo "$REPO" --version "$VERSION" -d "$STATE/charts" >/dev/null
    [ "$(sha256 "$CHART")" = "$SHA" ] || { echo "kyverno-$VERSION.tgz is not the archive charts.lock pins" >&2; exit 1; }
    say "kyverno chart $VERSION fetched and checked"
    ;;
  install)
    # The boundary's CA on kind, where the registry inside has a certificate
    # from it; ECR's is a public one, which Kyverno's image already trusts.
    trust=(--set-file "global.caCertificates.data=$STATE/ca.crt"); [ -z "${INSIDE:-}" ] || trust=()
    kyverno_images >"$STATE/kyverno-images.yaml"
    # ADMISSION_REPLICAS: more than one admission controller (ADR 20); the
    # chart then spreads them over the nodes and gives them a disruption
    # budget of its own.
    replicas=(); [ -z "${ADMISSION_REPLICAS:-}" ] || replicas=(--set "admissionController.replicas=$ADMISSION_REPLICAS")
    helm upgrade --install kyverno "$CHART" --namespace kyverno --create-namespace --wait --timeout 10m \
      -f "$STATE/kyverno-images.yaml" -f "$ROOT/admission/kyverno-values.yaml" "${trust[@]}" "${replicas[@]}" >/dev/null
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
    # The digests the bundle carried, from the layouts bundle.sh load
    # unpacked, as the parameter of the policy that holds every pod to them.
    find "$STATE/bundle.inside/oci" -name index.json -exec jq -r '.manifests[].digest' {} + | sort -u | tr '\n' ' ' \
      | sed 's/ $//' >"$STATE/carried-digests.txt"
    [ -s "$STATE/carried-digests.txt" ] || { echo "no bundle loaded: run scripts/bundle.sh load first" >&2; exit 1; }
    kubectl -n kube-system create configmap carried-images --from-file=digests="$STATE/carried-digests.txt" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl apply -f "$ROOT/admission/carried-images.yaml" >/dev/null
    model_volumes | kubectl apply -f - >/dev/null
    render_policy | kubectl apply -f - >/dev/null
    for _ in $(seq 1 60); do
      [ "$(kubectl get imagevalidatingpolicy verify-models -o jsonpath='{.status.conditionStatus.ready}' 2>/dev/null)" = true ] && break
      sleep 2
    done
    # The guard that refuses every model while Kyverno is away
    # (admission/kyverno-guard.yaml) reads Kyverno's webhook for
    # verify-models, so it goes on once that webhook is there. If it never
    # appears under that name, the guard would refuse every model for good:
    # stop here and say so.
    hook=ivpol.validate.kyverno.svc-fail-finegrained-verify-models
    for _ in $(seq 1 60); do
      kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o jsonpath='{.webhooks[*].name}' 2>/dev/null \
        | tr ' ' '\n' | grep -qx "$hook" && break
      sleep 2
    done
    kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o jsonpath='{.webhooks[*].name}' 2>/dev/null \
      | tr ' ' '\n' | grep -qx "$hook" \
      || { echo "Kyverno never registered $hook in kyverno-resource-validating-webhook-cfg; the guard would refuse every model" >&2; exit 1; }
    kubectl apply -f "$ROOT/admission/kyverno-guard.yaml" >/dev/null
    say "carried-images ($(wc -w <"$STATE/carried-digests.txt" | tr -d ' ') digests), model-volumes and verify-models applied, the last with the operator's key; models-need-kyverno on $hook"
    ;;
  *) echo "usage: admission.sh <fetch|install|policy>" >&2; exit 2 ;;
esac
