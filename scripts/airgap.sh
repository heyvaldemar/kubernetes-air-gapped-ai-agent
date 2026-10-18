#!/usr/bin/env bash
# airgap.sh <registry|seed|mirror|close> - build the boundary around the
# kind cluster, in that order.
#
#   registry  start zot, the registry inside the boundary, on kind's network,
#             under its own name, registry.boundary.internal, with TLS from a
#             CA made for this boundary (.cache/airgap/ca.crt)
#   seed      copy every image in airgap/images.txt into it by digest, with
#             the signatures and attestations that refer to it, under its
#             original host and path (docker.io/library/busybox stays
#             docker.io/library/busybox)
#   mirror    point the node's containerd at it for every upstream host, so
#             an image pulled by its original name is served from inside, and
#             teach the node the registry's name (/etc/hosts: the node has no
#             DNS once the boundary closes)
#   close     cut the cluster off: the runner's firewall refuses anything
#             from kind's bridge that is not to kind's bridge, the node has
#             no DNS server, and CoreDNS answers only for the cluster and the
#             registry's name
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
NAME=registry.boundary.internal
STATE="$ROOT/.cache/airgap"
CA="$STATE/ca.crt"
HOSTS=(docker.io ghcr.io quay.io registry.k8s.io reg.kyverno.io)
say() { printf '== %s\n' "$*"; }
nodes() { kind get nodes --name "$CLUSTER"; }
registry_ip() { docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' "$REGISTRY"; }

case "${1:-}" in
  registry)
    ref="$(grep -vE '^\s*(#|$)' "$ROOT/airgap/registry.ref")"
    mkdir -p "$STATE"
    # A CA for this boundary, and the registry's certificate from it: the name
    # pods and the node use, and 127.0.0.1 for seeding from the host.
    if [ ! -s "$CA" ]; then
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 \
        -subj "/CN=boundary CA" -keyout "$STATE/ca.key" -out "$CA" 2>/dev/null
    fi
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$NAME" \
      -keyout "$STATE/tls.key" -out "$STATE/tls.csr" 2>/dev/null
    printf 'subjectAltName=DNS:%s,DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' "$NAME" >"$STATE/tls.ext"
    openssl x509 -req -in "$STATE/tls.csr" -CA "$CA" -CAkey "$STATE/ca.key" -CAcreateserial -days 30 \
      -extfile "$STATE/tls.ext" -out "$STATE/tls.crt" 2>/dev/null
    chmod 644 "$STATE/tls.key"  # read by zot's non-root user inside its container
    docker rm -f "$REGISTRY" >/dev/null 2>&1 || true
    docker run -d --name "$REGISTRY" --network kind --restart=always \
      -v "$ROOT/airgap/zot.json:/etc/zot/config.json:ro" -v "$STATE:/etc/zot/tls:ro" \
      -p 127.0.0.1:5001:5000 "$ref" >/dev/null
    for _ in $(seq 1 30); do curl -fs --cacert "$CA" https://127.0.0.1:5001/v2/ >/dev/null && break; sleep 1; done
    curl -fs --cacert "$CA" https://127.0.0.1:5001/v2/ >/dev/null || { docker logs "$REGISTRY" | tail -20; exit 1; }
    say "zot is up as https://$NAME:5000 ($(registry_ip) on kind's network)"
    ;;
  seed)
    while read -r ref; do
      case "$ref" in ''|'#'*) continue ;; esac
      name="${ref%@*}"; digest="${ref#*@}"; repo="${name%:*}"; tag="${name##*:}"
      # Both the digest and the tag: a pod names the image by both, and the
      # copy keeps the digest because it copies the whole index.
      oras cp -r --to-ca-file "$CA" "$repo@$digest" "127.0.0.1:5001/$repo:$tag" >/dev/null
      got="$(oras manifest fetch --ca-file "$CA" --descriptor "127.0.0.1:5001/$repo:$tag" | sed -n 's/.*"digest":"\([^"]*\)".*/\1/p')"
      [ "$got" = "$digest" ] || { echo "seeded $repo:$tag as $got, wanted $digest" >&2; exit 1; }
      say "seeded $repo:$tag@${digest:0:19}"
    done <"$ROOT/airgap/images.txt"
    ;;
  mirror)
    ip="$(registry_ip)"
    for node in $(nodes); do
      docker exec "$node" sh -c "grep -q ' $NAME\$' /etc/hosts || echo '$ip $NAME' >> /etc/hosts"
      docker exec "$node" mkdir -p /etc/containerd/certs.d
      docker exec -i "$node" tee /etc/containerd/certs.d/boundary-ca.crt <"$CA" >/dev/null
      for host in "${HOSTS[@]}" "$NAME:5000"; do
        upstream="https://$host"; [ "$host" = docker.io ] && upstream="https://registry-1.docker.io"
        path="/v2/$host"; [ "$host" = "$NAME:5000" ] && path="/v2"
        docker exec "$node" mkdir -p "/etc/containerd/certs.d/$host"
        printf 'server = "%s"\n\n[host."https://%s:5000%s"]\n  capabilities = ["pull", "resolve"]\n  ca = "/etc/containerd/certs.d/boundary-ca.crt"\n  override_path = true\n' \
          "$upstream" "$NAME" "$path" | docker exec -i "$node" tee "/etc/containerd/certs.d/$host/hosts.toml" >/dev/null
      done
      say "$node pulls ${HOSTS[*]} and $NAME:5000 from https://$NAME:5000 ($ip)"
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
      | awk -v ip="$(registry_ip)" -v name="$NAME" '
          /^[[:space:]]*forward /{ if ($0 ~ /[{][[:space:]]*$/) skip=1; next }
          skip && /[}]/ { skip=0; next }
          skip { next }
          { print }
          /^\.:53 [{]/ { print "    hosts {"; print "        " ip " " name; print "        fallthrough"; print "    }" }' >"${TMPDIR:-/tmp}/Corefile"
    kubectl -n kube-system create configmap coredns --from-file=Corefile="${TMPDIR:-/tmp}/Corefile" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl -n kube-system rollout restart deployment/coredns >/dev/null
    kubectl -n kube-system rollout status deployment/coredns --timeout=120s >/dev/null
    say "closed: nothing from $br leaves it, the node has no DNS, CoreDNS answers only for the cluster and $NAME"
    ;;
  *) echo "usage: airgap.sh <registry|seed|mirror|close>" >&2; exit 2 ;;
esac
