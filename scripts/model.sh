#!/usr/bin/env bash
# model.sh <build|sign|plants> - the model as a signed image inside the
# boundary.
#
#   build   fetch the model file models/models.lock pins (by the publisher's
#           revision, checked against its sha256), build it into an OCI
#           image reproducibly, and push it into the registry inside. The
#           digest is the same on any machine with the pinned BuildKit; once
#           models.lock carries it, a build that differs fails
#   sign    sign that digest with the operator's key, without a transparency
#           log: nothing inside the boundary can reach one. CI makes the key
#           pair per run; in a real install the key is the operator's. cosign
#           3 refuses --tlog-upload=false under its default signing config,
#           so the key path turns that config off
#   plants  two small images the admission policy must refuse when a pod
#           mounts them: one nobody signed, one signed by a key the cluster
#           does not trust
#
# Runs before the boundary closes: build fetches the model from upstream.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$ROOT/.cache/airgap"
REG=registry.boundary.internal:5000
CA="$STATE/ca.crt"
BUILDKIT=moby/buildkit:v0.32.2@sha256:28a898719c18a33f4e8000685287fa36fd0dd9560c6440227d3a732d79bb41d8
say() { printf '== %s\n' "$*"; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
# MODEL picks a line of models/models.lock; the first is the default.
read -r MODEL URL SHA _license PINNED < <(grep -vE '^\s*(#|$)' "$ROOT/models/models.lock" | awk -v m="${MODEL:-}" 'm == "" || $1 == m' | head -n 1)

# cosign and oras read the registry's CA from the bundle they are given.
bundle() {
  local sys=/etc/ssl/certs/ca-certificates.crt
  [ -f "$sys" ] || sys=/etc/ssl/cert.pem
  cat "$sys" "$CA" >"$STATE/bundle.pem"
}

builder() {
  docker buildx inspect boundary >/dev/null 2>&1 \
    || docker buildx create --name boundary --driver docker-container --driver-opt "image=$BUILDKIT" >/dev/null
}

# attest <ref@digest> <bom.json>: the AI-BOM as an in-toto attestation,
# signed with the operator's key and no transparency log, like the signature.
attest() {
  SSL_CERT_FILE="$STATE/bundle.pem" COSIGN_PASSWORD="" \
    cosign attest --key "$STATE/operator.key" --type cyclonedx --predicate "$2" \
      --use-signing-config=false --tlog-upload=false --yes "$1" >/dev/null 2>&1
}

# image <dir> <repo:tag>: build <dir> reproducibly, push it, print its digest
image() {
  local dir="$1" ref="$2" layout digest
  layout="$STATE/$(basename "$dir").layout"
  SOURCE_DATE_EPOCH=0 docker buildx build --builder boundary --platform linux/amd64 \
    --provenance=false --sbom=false \
    --output "type=oci,dest=$layout.tar,rewrite-timestamp=true,compression=uncompressed" "$dir" >&2
  rm -rf "$layout" && mkdir -p "$layout" && tar -xf "$layout.tar" -C "$layout" && rm -f "$layout.tar"
  digest="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifests"][0]["digest"])' "$layout/index.json")"
  oras cp --from-oci-layout --to-ca-file "$CA" "$layout@$digest" "$REG/$ref" >/dev/null
  printf '%s\n' "$digest"
}

mkdir -p "$STATE"
case "${1:-}" in
  build)
    dir="$ROOT/.cache/models/$MODEL"
    mkdir -p "$dir"
    if [ ! -f "$dir/model.gguf" ] || [ "$(sha256 "$dir/model.gguf")" != "$SHA" ]; then
      curl -fL --retry 3 -o "$dir/model.gguf" "$URL"
    fi
    [ "$(sha256 "$dir/model.gguf")" = "$SHA" ] || { echo "$MODEL: the file's sha256 is not the pinned $SHA" >&2; exit 1; }
    cp "$ROOT/models/Dockerfile" "$dir/Dockerfile"
    builder
    digest="$(image "$dir" "models/$MODEL:q4_k_m")"
    printf '%s\n' "$digest" >"$STATE/$MODEL.digest"
    # The registry holds it now; the file, the layout and BuildKit's cache
    # would hold it three more times on a runner's disk.
    rm -rf "$dir/model.gguf" "$STATE/$(basename "$dir").layout"
    docker buildx rm boundary >/dev/null 2>&1 || true
    if [ "$PINNED" != unpinned ] && [ "$PINNED" != "$digest" ]; then
      echo "$MODEL built as $digest; models/models.lock pins $PINNED. The build is not reproducible, or the pin is stale." >&2
      exit 1
    fi
    say "$REG/models/$MODEL@$digest${PINNED:+ (models.lock: $PINNED)}"
    ;;
  sign)
    bundle
    for who in operator stranger; do
      [ -s "$STATE/$who.key" ] || COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix "$STATE/$who" >/dev/null
    done
    digest="$(cat "$STATE/$MODEL.digest")"
    SSL_CERT_FILE="$STATE/bundle.pem" COSIGN_PASSWORD="" \
      cosign sign --key "$STATE/operator.key" --use-signing-config=false --tlog-upload=false --yes "$REG/models/$MODEL@$digest" >/dev/null
    # THE AI-BOM: what the model is, where its file came from at which
    # revision, its sha256 and its licence, as a CycloneDX ML-BOM attested
    # with the same key. Admission reads the licence before the model may
    # be mounted (admission/verify-models.yaml).
    python3 "$ROOT/scripts/mlbom.py" "$MODEL" "$URL" "$SHA" "$_license" >"$STATE/$MODEL.mlbom.json"
    attest "$REG/models/$MODEL@$digest" "$STATE/$MODEL.mlbom.json"
    say "signed $REG/models/$MODEL@${digest:0:19} with the operator's key, no transparency log, and attested its AI-BOM ($_license)"
    ;;
  plants)
    bundle; builder
    for name in unsigned stranger unlicensed nobom; do
      dir="$STATE/plant-$name"; mkdir -p "$dir"
      printf 'not a model: %s\n' "$name" >"$dir/model.gguf"
      cp "$ROOT/models/Dockerfile" "$dir/Dockerfile"
      digest="$(image "$dir" "models/plant-$name:v1")"
      printf '%s\n' "$digest" >"$STATE/plant-$name.digest"
    done
    SSL_CERT_FILE="$STATE/bundle.pem" COSIGN_PASSWORD="" \
      cosign sign --key "$STATE/stranger.key" --use-signing-config=false --tlog-upload=false --yes "$REG/models/plant-stranger@$(cat "$STATE/plant-stranger.digest")" >/dev/null
    # Signed by the operator, so only the AI-BOM can refuse them: one carries
    # none, one declares a licence the site does not allow.
    for name in unlicensed nobom; do
      SSL_CERT_FILE="$STATE/bundle.pem" COSIGN_PASSWORD="" \
        cosign sign --key "$STATE/operator.key" --use-signing-config=false --tlog-upload=false --yes "$REG/models/plant-$name@$(cat "$STATE/plant-$name.digest")" >/dev/null
    done
    python3 "$ROOT/scripts/mlbom.py" plant-unlicensed "https://huggingface.co/plant/unlicensed/resolve/0000000000000000000000000000000000000000/model.gguf" \
      "$(sha256 "$STATE/plant-unlicensed/model.gguf")" GPL-3.0-only >"$STATE/plant-unlicensed.mlbom.json"
    attest "$REG/models/plant-unlicensed@$(cat "$STATE/plant-unlicensed.digest")" "$STATE/plant-unlicensed.mlbom.json"
    say "plants: models/plant-unsigned (no signature), models/plant-stranger (signed by a key the cluster does not trust), models/plant-unlicensed (signed, AI-BOM says GPL-3.0-only), models/plant-nobom (signed, no AI-BOM)"
    ;;
  *) echo "usage: model.sh <build|sign|plants>" >&2; exit 2 ;;
esac
