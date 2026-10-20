#!/usr/bin/env bash
# airgap.sh <registry|seed|mirror|close|open> - build the boundary around
# the kind cluster, in that order, and take it down again.
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
#   open      undo what close and registry did to the host: the firewall
#             rules, the registry container and the host's /etc/hosts entry
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
HOSTS=(docker.io ghcr.io quay.io registry.k8s.io reg.kyverno.io cr.agentgateway.dev)
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
      -p 127.0.0.1:5000:5000 "$ref" >/dev/null
    # The host reaches it by the same name the cluster does, so a signature
    # names the image exactly as the admission policy will look it up.
    grep -q " $NAME$" /etc/hosts || echo "127.0.0.1 $NAME" | sudo tee -a /etc/hosts >/dev/null
    for _ in $(seq 1 30); do curl -fs --cacert "$CA" "https://$NAME:5000/v2/" >/dev/null && break; sleep 1; done
    curl -fs --cacert "$CA" "https://$NAME:5000/v2/" >/dev/null || { docker logs "$REGISTRY" | tail -20; exit 1; }
    say "zot is up as https://$NAME:5000 ($(registry_ip) on kind's network)"
    ;;
  seed)
    while read -r ref; do
      case "$ref" in ''|'#'*) continue ;; esac
      name="${ref%@*}"; digest="${ref#*@}"; repo="${name%:*}"; tag="${name##*:}"
      # Both the digest and the tag: a pod names the image by both, and the
      # copy keeps the digest because it copies the whole index.
      # With what refers to it (signatures, attestations) where the source
      # serves the referrers API. reg.kyverno.io does not: its images come
      # in without, and the run says so rather than failing or staying quiet.
      if ! oras cp -r --to-ca-file "$CA" "$repo@$digest" "$NAME:5000/$repo:$tag" >/dev/null 2>"$STATE/seed.err"; then
        oras cp --to-ca-file "$CA" "$repo@$digest" "$NAME:5000/$repo:$tag" >/dev/null
        echo "   (no referrers copied: ${repo%%/*} answered \"$(tr -d '\n' <"$STATE/seed.err" | cut -c1-80)\")"
      fi
      got="$(oras manifest fetch --ca-file "$CA" --descriptor "$NAME:5000/$repo:$tag" | sed -n 's/.*"digest":"\([^"]*\)".*/\1/p')"
      [ "$got" = "$digest" ] || { echo "seeded $repo:$tag as $got, wanted $digest" >&2; exit 1; }
      say "seeded $repo:$tag@${digest:0:19}"
    done <"$ROOT/airgap/images.txt"
    ;;
  mirror)
    ip="$(registry_ip)"
    for node in $(nodes); do
      # Replaced, not appended once: the registry inside may be a new container
      # with a new address (bundle.sh's path replaces the staging one). The
      # file is a bind mount, so it is rewritten in place, not renamed.
      docker exec "$node" sh -c "grep -v ' $NAME\$' /etc/hosts > /tmp/hosts.new; echo '$ip $NAME' >> /tmp/hosts.new; cat /tmp/hosts.new > /etc/hosts"
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
      # The host itself. Traffic addressed to the host takes INPUT, which the
      # rule above (FORWARD) never sees: a pod could open the host's SSH port
      # until this rule. Nothing in the cluster opens a connection to the
      # host; replies to the host's own connections (kubectl to the API
      # server) are not new, and pass.
      sudo "$t" -C INPUT -i "$br" -m conntrack --ctstate NEW -j REJECT 2>/dev/null \
        || sudo "$t" -I INPUT 1 -i "$br" -m conntrack --ctstate NEW -j REJECT
    done
    for node in $(nodes); do
      docker exec "$node" sh -c 'printf "nameserver 127.0.0.1\n" > /etc/resolv.conf'
      # Docker's embedded DNS, inside the node. kind's entrypoint sends the
      # bridge gateway's port 53 (UDP and TCP), from the node and from its
      # pods, to Docker's resolver at 127.0.0.11, and dockerd answers from
      # the host, where no rule on the bridge sees it. A pod asked it for
      # example.com and got an answer until these chains were emptied.
      for t in iptables ip6tables; do
        for chain in DOCKER_OUTPUT DOCKER_POSTROUTING; do
          docker exec "$node" "$t" -t nat -F "$chain" 2>/dev/null || true
        done
      done
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
    say "closed: nothing from $br leaves it or opens a connection to the host, the node has no DNS and no way to Docker's, CoreDNS answers only for the cluster and $NAME"
    ;;
  open)
    if br="br-$(docker network inspect kind -f '{{.Id}}' 2>/dev/null | cut -c1-12)" && [ "$br" != "br-" ]; then
      for t in iptables ip6tables; do
        while sudo "$t" -C DOCKER-USER -i "$br" ! -o "$br" -j REJECT 2>/dev/null; do
          sudo "$t" -D DOCKER-USER -i "$br" ! -o "$br" -j REJECT
        done
        while sudo "$t" -C INPUT -i "$br" -m conntrack --ctstate NEW -j REJECT 2>/dev/null; do
          sudo "$t" -D INPUT -i "$br" -m conntrack --ctstate NEW -j REJECT
        done
      done
    fi
    docker rm -f "$REGISTRY" >/dev/null 2>&1 || true
    if grep -q " $NAME$" /etc/hosts; then
      grep -v " $NAME$" /etc/hosts >"$STATE/hosts.new" && sudo cp "$STATE/hosts.new" /etc/hosts
    fi
    say "opened: the firewall rules, the registry and the host's entry for $NAME are gone"
    ;;
  *) echo "usage: airgap.sh <registry|seed|mirror|close|open>" >&2; exit 2 ;;
esac
