# 1. The boundary is the host's firewall, the node's resolver and CoreDNS

- Status: accepted, amended 2026-10-20 (Docker's DNS inside the node, and the host itself)
- Date: 2026-10-18

## Context

An air-gapped install is a cluster with no route out. To prove one in CI, the cluster has to be cut off after it is built and before anything it runs is installed, and the cut has to be checked from inside, not assumed.

The obvious tool does not work. A Docker network created with `--internal` has no route out, but kind cannot create a cluster on one: it reads the API server's host port from the container's published ports, and an internal network publishes none (kubernetes-sigs/kind#2776, open since 2022). Its maintainers suggest firewall rules on the host instead.

A firewall rule is not the whole of it either. A kind node resolves names through Docker's embedded DNS server, and dockerd forwards those queries from the host, outside any rule on the bridge. A lookup is a way out: data can be encoded into the names an attacker asks for.

## Decision

`scripts/airgap.sh close` cuts in three places, after the registry inside is seeded:

1. **The host's firewall.** A rule at the top of `DOCKER-USER`, for IPv4 and IPv6, rejects anything that enters from kind's bridge and does not leave through it. The node and the registry share the bridge, so they still reach each other; nothing reaches beyond it.
2. **The node's resolver, and the way to Docker's.** The node's `/etc/resolv.conf` points at 127.0.0.1, where nothing listens. The node needs no names: containerd reaches the registry through `/etc/hosts`. kind's entrypoint also sends the bridge gateway's port 53, from the node and from its pods, to Docker's embedded resolver; the node's `DOCKER_OUTPUT` and `DOCKER_POSTROUTING` NAT chains, which do that, are emptied (since 2026-10-20).
3. **CoreDNS.** Its `forward` block goes, so it answers for the cluster and for the registry's name (a `hosts` entry) and for nothing else. kind's own offline CI removes the same block, so that the answer is NXDOMAIN rather than a timeout clients keep retrying.
4. **The host itself** (added 2026-10-20). A rule at the top of `INPUT`, for IPv4 and IPv6, rejects any new connection from kind's bridge to the host, whose SSH port a pod could open before. Replies to the host's own connections, kubectl's to the API server among them, are not new, and pass.

`tests/e2e/run.sh` then proves it from inside: a pod and the node each fail to reach 1.1.1.1 by IP and to resolve example.com, the node fails to pull an image the registry inside does not hold, and an image it does hold comes up by its original name and digest.

## What the first three missed

Until 2026-10-20 nothing checked the host's address on the bridge from a pod. The probes added to `tests/e2e/run.sh` that day found two ways out there (172.18.0.1 on a GitHub runner).

- **TCP 22.** Traffic addressed to the host takes `INPUT`, and the rule in step 1, in `FORWARD`, never sees it. A pod could open the host's SSH port.
- **Port 53, answered.** A pod asked 172.18.0.1 for example.com and got an address (run [39371733895](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39371733895)). A rule in `INPUT` did not stop it (run [39373144875](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39373144875)): the query never reached the host's `INPUT`. Inside the node, kind's entrypoint rewrites Docker's NAT rules so that the gateway's port 53 goes to Docker's embedded resolver at 127.0.0.11, for the node and, through a `PREROUTING` jump, for its pods; dockerd answers from the host, where no rule on the bridge applies (run [39374222983](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39374222983) printed the rules). That is the way out by DNS this record's context names, reached from a pod rather than from the node's own resolver, which step 2 had closed.

Every release before v1.5.0 had both. Step 2 now empties the node's Docker NAT chains, step 4 closes `INPUT`, and the probes gate both: no port on the host opens from a pod, and no outside name resolves through the gateway.

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
