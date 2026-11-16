#!/usr/bin/env bash
# serve.sh - deploy the model server with the signed model, and wait until it
# answers. The model image is named by digest: the pin in models/models.lock,
# or, until there is one, the digest this run built. Both images come from the
# registry inside (scripts/inside.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$ROOT/.cache/airgap"
# shellcheck source=scripts/inside.sh
. "$ROOT/scripts/inside.sh"
# MODEL picks a line of models/models.lock; the first is the default.
# MODELS_LOCK: another file of the same lines, for a run that serves models
# this repository does not pin (ADR 19, 2026-11-16).
MODELS_LOCK="${MODELS_LOCK:-$ROOT/models/models.lock}"
read -r MODEL _rest < <(grep -vE '^\s*(#|$)' "$MODELS_LOCK" | awk -v m="${MODEL:-}" 'm == "" || $1 == m' | head -n 1)
PINNED="${_rest##* }"  # the last field; a licence before it may hold spaces
digest="$PINNED"; [ "$digest" = unpinned ] && digest="$(cat "$STATE/$MODEL.digest")"
ref="$MODELS/$MODEL@$digest"
# SERVE_NAME names the server: llama for the evals, one name per model when a
# run serves two side by side behind the gateway.
NAME="${SERVE_NAME:-llama}"
# SERVE_MANIFEST: the GPU server's (ADR 19) instead of the CPU server's.
MANIFEST="${SERVE_MANIFEST:-$ROOT/manifests/inference/llama.yaml}"
# GPU_SLOTS: how many requests the GPU server takes at once, 8192 tokens of
# context each, as the CPU server has for its one. Eight unless a run says
# otherwise: a model that fills the GPU's memory has no room for eight
# (ADR 19, 2026-11-16). Only the GPU server's manifest names them.
GPU_SLOTS="${GPU_SLOTS:-8}"
case "$GPU_SLOTS" in
  ''|0*|*[!0-9]*) echo "serve.sh: GPU_SLOTS is a whole number above zero, not '$GPU_SLOTS'" >&2; exit 1 ;;
esac
# SERVE_REPLICAS: more than one server, spread over the nodes (ADR 20).
sed -e "s#@MODEL@#$ref#" -e "s#@NAME@#$NAME#g" -e "s#@ALIAS@#$MODEL#g" \
  -e "s#@SLOTS@#$GPU_SLOTS#" -e "s#@CONTEXT@#$((8192 * GPU_SLOTS))#" \
  -e "s#^  replicas: 1\$#  replicas: ${SERVE_REPLICAS:-1}#" "$MANIFEST" | relocate | kubectl apply -f - >/dev/null
kubectl -n inference rollout status "deployment/$NAME" --timeout=600s >/dev/null
printf '== llama-server %s is up, serving %s\n' "$NAME" "$ref"
