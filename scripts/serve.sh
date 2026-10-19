#!/usr/bin/env bash
# serve.sh - deploy the model server with the signed model, and wait until it
# answers. The model image is named by digest: the pin in models/models.lock,
# or, until there is one, the digest this run built.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$ROOT/.cache/airgap"
# MODEL picks a line of models/models.lock; the first is the default.
read -r MODEL _ _ _ PINNED < <(grep -vE '^\s*(#|$)' "$ROOT/models/models.lock" | awk -v m="${MODEL:-}" 'm == "" || $1 == m' | head -n 1)
digest="$PINNED"; [ "$digest" = unpinned ] && digest="$(cat "$STATE/$MODEL.digest")"
ref="registry.boundary.internal:5000/models/$MODEL@$digest"
# SERVE_NAME names the server: llama for the evals, one name per model when a
# run serves two side by side behind the gateway.
NAME="${SERVE_NAME:-llama}"
sed -e "s#@MODEL@#$ref#" -e "s#@NAME@#$NAME#g" -e "s#@ALIAS@#$MODEL#g" "$ROOT/manifests/inference/llama.yaml" | kubectl apply -f - >/dev/null
kubectl -n inference rollout status "deployment/$NAME" --timeout=600s >/dev/null
printf '== llama-server %s is up, serving %s\n' "$NAME" "$ref"
