# 1. The boundary is the host's firewall, the node's resolver and CoreDNS

- Status: accepted, amended 2026-10-20 (the host itself)
- Date: 2026-10-18

## Context

An air-gapped install is a cluster with no route out. To prove one in CI, the cluster has to be cut off after it is built and before anything it runs is installed, and the cut has to be checked from inside, not assumed.

The obvious tool does not work. A Docker network created with `--internal` has no route out, but kind cannot create a cluster on one: it reads the API server's host port from the container's published ports, and an internal network publishes none (kubernetes-sigs/kind#2776, open since 2022). Its maintainers suggest firewall rules on the host instead.

A firewall rule is not the whole of it either. A kind node resolves names through Docker's embedded DNS server, and dockerd forwards those queries from the host, outside any rule on the bridge. A lookup is a way out: data can be encoded into the names an attacker asks for.

## Decision

`scripts/airgap.sh close` cuts in three places, after the registry inside is seeded:

1. **The host's firewall.** A rule at the top of `DOCKER-USER`, for IPv4 and IPv6, rejects anything that enters from kind's bridge and does not leave through it. The node and the registry share the bridge, so they still reach each other; nothing reaches beyond it.
2. **The node's resolver.** The node's `/etc/resolv.conf` points at 127.0.0.1, where nothing listens. The node needs no names: containerd reaches the registry through `/etc/hosts`.
3. **CoreDNS.** Its `forward` block goes, so it answers for the cluster and for the registry's name (a `hosts` entry) and for nothing else. kind's own offline CI removes the same block, so that the answer is NXDOMAIN rather than a timeout clients keep retrying.
4. **The host itself** (added 2026-10-20). A rule at the top of `INPUT`, for IPv4 and IPv6, rejects any new connection from kind's bridge to the host. Replies to the host's own connections, kubectl's to the API server among them, are not new, and pass.

`tests/e2e/run.sh` then proves it from inside: a pod and the node each fail to reach 1.1.1.1 by IP and to resolve example.com, the node fails to pull an image the registry inside does not hold, and an image it does hold comes up by its original name and digest.

## What the first three missed

Traffic addressed to the host does not cross `DOCKER-USER`: it takes `INPUT`, and the rule in step 1 never sees it. Until 2026-10-20 nothing closed it, and nothing checked it. The probes added to `tests/e2e/run.sh` that day found a pod could open TCP 22 and 53 on the host's address on the bridge (172.18.0.1 on a GitHub runner), and the resolver on 53 answered a pod's query for example.com (run [39371733895](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39371733895), "a pod resolved example.com by asking the host itself"). That is the way out by DNS this record names in its context, through the host's resolver instead of the node's. Every release before v1.5.0 had it. Step 4 closes it, and the same probes now gate it: no port on the host opens from a pod, and no outside name resolves through it.

## Consequences

- The proof is the same checks on every run, not a diagram: a pod and the node reaching nothing outside, each beside a control that must reach the registry inside, a pod reaching nothing on the host, and every way of asking for an outside name failing.
- `close` needs the host's iptables: it runs on Linux, the GitHub runner included. The other steps run anywhere Docker does.
- In a real site the boundary is the site's network and firewall, not a rule on one host. What carries over is the order (seed, close, then install) and the checks.
- The host itself is outside the boundary: it fetches the model and the images before the cut, as a transfer station would.

## Alternatives

- **An `--internal` Docker network.** Cannot host kind today (kind#2776).
- **NetworkPolicy alone.** Covers pods, not the node: containerd pulls run on the node, and a policy says nothing about them. It is used here as well, for the agents' own traffic.
- **Cilium's host firewall.** Covers the node too, at the cost of replacing kind's CNI; the firewall rule proves the same thing with less.

## How to explain this to a customer

Your cluster has no way out to the internet, and we do not take that on trust: on every run, the cluster tries to reach an outside address, to look up an outside name and to download something that was not brought in, and every attempt has to fail. What it needs was brought in beforehand, checked, and put in a registry inside. If it is not in that registry, it does not run.
