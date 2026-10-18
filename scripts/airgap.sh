#!/usr/bin/env bash
# airgap.sh <registry|seed|mirror|close> - build the boundary around the
# kind cluster, in that order.
#
#   registry  start zot, the registry inside the boundary, on kind's network
#   seed      copy every image in airgap/images.txt into it by digest, with
#             the signatures and attestations that refer to it, under its
#             original host and path (docker.io/library/busybox stays
#             docker.io/library/busybox)
#   mirror    point the node's containerd at it for every upstream host, by
#             IP address, so an image pulled by its original name is served
#             from inside
#   close     cut the cluster off: the runner's firewall refuses anything
#             from kind's bridge that is not to kind's bridge, the node has
#             no DNS server, and CoreDNS answers only for the cluster
#
# Why the firewall and not a Docker network with no route out: kind cannot
# create a cluster on an --internal network today (kubernetes-sigs/kind#2776,
# open since 2022), and its maintainers suggest host firewall rules instead.
# Why the node's DNS too: the node resolves through Docker's embedded DNS,
# which dockerd forwards from the host, outside the rule above. A lookup is a
# way out; this closes it rather than listing it as a residual risk.
#
# Linux only for `close`: it needs the host's iptables (CI runs it on the
# GitHub runner). The other steps run anywhere Docker does.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="${CLUSTER:-air-gapped}"
REGISTRY=kind-registry
HOSTS=(docker.io ghcr.io quay.io registry.k8s.io reg.kyverno.io)
say() { printf '== %s\n' "$*"; }
nodes() { kind get nodes --name "$CLUSTER"; }
registry_ip() { docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' "$REGISTRY"; }

case "${1:-}" in
  registry)
    ref="$(grep -vE '^\s*(#|$)' "$ROOT/airgap/registry.ref")"
    docker rm -f "$REGISTRY" >/dev/null 2>&1 || true
    docker run -d --name "$REGISTRY" --network kind --restart=always \
      -v "$ROOT/airgap/zot.json:/etc/zot/config.json:ro" -p 127.0.0.1:5001:5000 "$ref" >/dev/null
    for _ in $(seq 1 30); do curl -fs http://127.0.0.1:5001/v2/ >/dev/null && break; sleep 1; done
    curl -fs http://127.0.0.1:5001/v2/ >/dev/null || { docker logs "$REGISTRY" | tail -20; exit 1; }
    say "zot is up on kind's network at $(registry_ip):5000"
    ;;
  seed)
    while read -r ref; do
      case "$ref" in ''|'#'*) continue ;; esac
      name="${ref%@*}"; digest="${ref#*@}"; repo="${name%:*}"; tag="${name##*:}"
      # Both the digest and the tag: a pod names the image by both, and the
      # copy keeps the digest because it copies the whole index.
      oras cp -r --to-plain-http "$repo@$digest" "127.0.0.1:5001/$repo:$tag" >/dev/null
      got="$(oras manifest fetch --plain-http --descriptor "127.0.0.1:5001/$repo:$tag" | sed -n 's/.*"digest":"\([^"]*\)".*/\1/p')"
      [ "$got" = "$digest" ] || { echo "seeded $repo:$tag as $got, wanted $digest" >&2; exit 1; }
      say "seeded $repo:$tag@${digest:0:19}"
    done <"$ROOT/airgap/images.txt"
    ;;
  mirror)
    ip="$(registry_ip)"
    for node in $(nodes); do
      for host in "${HOSTS[@]}"; do
        upstream="https://$host"; [ "$host" = docker.io ] && upstream="https://registry-1.docker.io"
        docker exec "$node" mkdir -p "/etc/containerd/certs.d/$host"
        printf 'server = "%s"\n\n[host."http://%s:5000/v2/%s"]\n  capabilities = ["pull", "resolve"]\n  override_path = true\n' \
          "$upstream" "$ip" "$host" | docker exec -i "$node" tee "/etc/containerd/certs.d/$host/hosts.toml" >/dev/null
      done
      say "$node pulls ${HOSTS[*]} from $ip:5000"
    done
    ;;
  close)
    br="br-$(docker network inspect kind -f '{{.Id}}' | cut -c1-12)"
    for t in iptables ip6tables; do
      sudo "$t" -C DOCKER-USER -i "$br" ! -o "$br" -j REJECT 2>/dev/null \
        || sudo "$t" -I DOCKER-USER 1 -i "$br" ! -o "$br" -j REJECT
    done
    for node in $(nodes); do
      docker exec "$node" sh -c 'printf "nameserver 127.0.0.1\n" > /etc/resolv.conf'
    done
    # CoreDNS forwards what it does not own to the node's resolver; with that
    # gone it would time out. kind's own offline CI removes the block so the
    # answer is NXDOMAIN, which clients stop retrying.
    kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' \
      | awk '/^[[:space:]]*forward /{ if ($0 ~ /[{][[:space:]]*$/) skip=1; next } skip && /[}]/ { skip=0; next } !skip' >"${TMPDIR:-/tmp}/Corefile"
    kubectl -n kube-system create configmap coredns --from-file=Corefile="${TMPDIR:-/tmp}/Corefile" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl -n kube-system rollout restart deployment/coredns >/dev/null
    kubectl -n kube-system rollout status deployment/coredns --timeout=120s >/dev/null
    say "closed: nothing from $br leaves it, the node has no DNS, CoreDNS owns only the cluster"
    ;;
  *) echo "usage: airgap.sh <registry|seed|mirror|close>" >&2; exit 2 ;;
esac
