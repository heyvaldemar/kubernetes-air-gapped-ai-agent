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
sed "s#@MODEL@#$ref#" "$ROOT/manifests/inference/llama.yaml" | kubectl apply -f - >/dev/null
kubectl -n inference rollout status deployment/llama --timeout=600s >/dev/null
printf '== llama-server is up, serving %s\n' "$ref"
