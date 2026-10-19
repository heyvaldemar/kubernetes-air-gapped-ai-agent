#!/usr/bin/env bash
# bundle.sh <create|load> - carry everything the cluster runs across the gap
# as one signed file, the way it reaches a site that has no route out.
#
#   create  outside, connected: every repository and tag in the staging
#           registry (the images airgap.sh seeded, the model images, their
#           signatures) copied with what refers to them into OCI layouts, the
#           admission chart beside them, a SHA256SUMS over every file, all in
#           one tar, signed with the operator's key and no transparency log
#   load    inside, after the cut: refuse the file unless the operator's
#           signature verifies and every checksum matches, then copy each
#           layout into the registry inside and put the chart where
#           admission.sh installs it from
#
# The registry the cluster pulls from is empty until `load` runs: the e2e
# run starts a fresh one after `create` and checks that it holds nothing
# before the bundle goes in, and that a bundle changed by one byte is
# refused. Nothing reaches the cluster except through this file.
#
#   BUNDLE  the file (default .cache/airgap/bundle.tar; its signature is
#           BUNDLE.sigstore.json beside it)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$ROOT/.cache/airgap"
NAME=registry.boundary.internal
REG="$NAME:5000"
CA="$STATE/ca.crt"
BUNDLE="${BUNDLE:-$STATE/bundle.tar}"
CHART_DIR="$STATE/charts"
say() { printf '== %s\n' "$*"; }
api() { curl -fsS --cacert "$CA" "https://$REG/v2/$1"; }

case "${1:-}" in
  create)
    work="$STATE/bundle.d"
    rm -rf "$work" && mkdir -p "$work/oci" "$work/charts"
    n=0
    for repo in $(api "_catalog?n=10000" | jq -r '.repositories[]'); do
      for tag in $(api "$repo/tags/list" | jq -r '.tags[]?'); do
        # -r: the signatures and attestations that refer to an image travel
        # with it. One layout per repository, so its path is its name.
        oras cp -r --from-ca-file "$CA" "$REG/$repo:$tag" --to-oci-layout "$work/oci/$repo:$tag" >/dev/null
        n=$((n + 1))
      done
    done
    # Charts and the manifests that travel with them (the gateway's CRDs).
    cp "$CHART_DIR"/* "$work/charts/"
    (cd "$work" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) >"$STATE/SHA256SUMS.tmp"
    mv "$STATE/SHA256SUMS.tmp" "$work/SHA256SUMS"
    # The same bytes for the same contents: sorted, no times, no owners.
    tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf "$BUNDLE" -C "$work" .
    COSIGN_PASSWORD="" cosign sign-blob --key "$STATE/operator.key" --tlog-upload=false --use-signing-config=false \
      --bundle "$BUNDLE.sigstore.json" --yes "$BUNDLE" >/dev/null 2>&1
    # The file is what crosses; the layouts it was made from are not kept
    # beside it on a runner's disk.
    rm -rf "$work"
    say "bundle: $n image tags and the chart, $(du -h "$BUNDLE" | cut -f1), sha256 $(sha256sum "$BUNDLE" | cut -c1-16)..., signed with the operator's key"
    ;;
  load)
    # The signature first, the contents second: nothing in a file that does
    # not verify is read, let alone loaded.
    if ! cosign verify-blob --key "$STATE/operator.pub" --bundle "$BUNDLE.sigstore.json" \
        --insecure-ignore-tlog=true "$BUNDLE" >/dev/null 2>&1; then
      echo "refused: $BUNDLE does not verify against the operator's key; nothing loaded" >&2
      exit 1
    fi
    # What the registry held before this file went in, for the acceptance
    # test: on a fresh boundary it must be nothing.
    before="$(api "_catalog?n=10000" | jq -r '.repositories | length')"
    inside="$STATE/bundle.inside"
    rm -rf "$inside" && mkdir -p "$inside"
    tar -xf "$BUNDLE" -C "$inside"
    (cd "$inside" && sha256sum --quiet -c SHA256SUMS) || { echo "refused: a checksum in the bundle does not match; nothing loaded" >&2; exit 1; }
    n=0
    while IFS= read -r index; do
      layout="$(dirname "$index")"
      repo="${layout#"$inside/oci/"}"
      for tag in $(jq -r '.manifests[].annotations["org.opencontainers.image.ref.name"] // empty' "$index" | sort -u); do
        oras cp -r --from-oci-layout "$layout:$tag" --to-ca-file "$CA" "$REG/$repo:$tag" >/dev/null
        n=$((n + 1))
      done
    done < <(find "$inside/oci" -name index.json | sort)
    mkdir -p "$CHART_DIR" && cp "$inside"/charts/* "$CHART_DIR/"
    # The blobs are in the registry now. The indexes stay, so the acceptance
    # test can compare what the registry holds with what the file carried.
    find "$inside/oci" -path '*/blobs/*' -type f -delete
    printf 'repositories_before=%s\ntags_loaded=%s\nsha256=%s\n' "$before" "$n" "$(sha256sum "$BUNDLE" | cut -d' ' -f1)" >"$STATE/bundle.loaded"
    say "loaded $n image tags into https://$REG from a bundle that verified, and the chart into .cache/airgap/charts"
    ;;
  *)
    echo "usage: bundle.sh <create|load>" >&2
    exit 2
    ;;
esac
