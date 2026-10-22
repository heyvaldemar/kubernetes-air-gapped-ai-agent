# shellcheck shell=bash disable=SC2034  # read by the scripts that source it
# inside.sh - sourced, not run: the registry inside, where the cluster pulls
# everything from.
#
# On kind it is registry.boundary.internal:5000, and the node's containerd
# serves every image by its original name from it (airgap.sh mirror). In a
# cloud account (ADR 18) it is INSIDE, the run's own path in the account's
# registry: <account>.dkr.ecr.<region>.amazonaws.com/<cluster>. A mirror rule
# cannot give the node's containerd the credential ECR asks for, so there
# every image is named under INSIDE instead, by the same path and digest:
# docker.io/library/busybox@sha256:... becomes
# $INSIDE/docker.io/library/busybox@sha256:...
#
#   REG        the registry inside: INSIDE when set, the kind one otherwise
#   MODELS     where model weights come from, REG/models
#   relocate   the manifests on stdin, with every image: line under INSIDE
#   relocated  one image reference under INSIDE
REG="${INSIDE:-registry.boundary.internal:5000}"
MODELS="$REG/models"
relocate() {
  if [ -n "${INSIDE:-}" ]; then
    sed -E "s#^([[:space:]-]*image:[[:space:]]*[\"']?)([a-z0-9-]+(\.[a-z0-9-]+)+(:[0-9]+)?/)#\1$INSIDE/\2#"
  else
    cat
  fi
}
relocated() { printf '%s\n' "${INSIDE:+$INSIDE/}$1"; }
