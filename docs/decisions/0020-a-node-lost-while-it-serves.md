# 20. A node lost while it serves: two of everything the boundary depends on

- Status: accepted, 2026-10-24
- Date: 2026-10-24

## Context

Until now every service ran one replica, on one kind node or one EKS node. The game day (ADR 17) takes one control down at a time, on purpose, and asks which way it fails. A node takes them all at once: the model server, the gateway's proxy and its controller, Kyverno's admission controller, and whatever else the scheduler put there. A platform reviewer asks four things about that. Does admission still refuse what it must when its replica dies with the node? How long does serving stop? Does a planned drain cost anything? And does a node that comes back come back inside the boundary?

## Decision

- **Two of each, on two nodes.** The model server spreads its replicas over the nodes (`topologySpreadConstraints`, `SERVE_REPLICAS`). The gateway runs two proxies (`AgentgatewayParameters`) and two controllers (its chart), both spread (`GATEWAY_REPLICAS`). Kyverno runs two admission controllers (`ADMISSION_REPLICAS`), which its chart keeps apart. Each has a disruption budget that lets one go at a time (`manifests/ha/disruption-budgets.yaml`; Kyverno's and the gateway controller's come from their charts). One replica stays the default everywhere else.
- **The drill** (`tests/e2e/nodeloss.sh`): on a cluster with two workers, a request through the gateway every 0.75 s from a client on the worker that stays, each given 10 s, and every two seconds a pod that mounts a model nobody signed and one that mounts the signed model, tried at admission. Then three things happen to the other worker:
  1. lost the way a crash loses it: on kind its container killed, on AWS its instance terminated;
  2. back: the same container started, or the instance the node group launches in its place, and the boundary tried from a pod on it with the node's own resolver;
  3. drained, the way maintenance and upgrades take a node.
- **The checks.** The model nobody signed is refused every time it is tried, through all three. After the loss the gateway answers again, and admission admits the signed model, with one replica of each. The node that comes back resolves no outside name and opens no connection out. A drain costs no request and no admission. What the loss costs in failed requests, in seconds and in refused admissions is measured, not gated.
- **Daily on kind, by hand on AWS.** On kind in the daily e2e (`.github/workflows/nodeloss.yml`, `kind/ha.yaml`: the control plane and two workers in two zones). On AWS with `ha: true` on a dispatch: two CPU nodes (`nodes = 2`), the same replicas and budgets, and the drill with `NODE_LOSS=aws` after the game day.
- **A kind node closes itself at boot.** `scripts/airgap.sh close` writes the registry's and the control plane's addresses into each node's hosts file, and installs a unit that, at every boot and before containerd and the kubelet, puts those two names back, points the node's resolver nowhere, and empties Docker's two NAT chains.

## On kind, 2026-10-24

Three runs on the branch, each finding what the next fixed.

- [40108045991](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/40108045991): the worker that came back resolved example.com itself. Docker gives a container that starts again its resolver and its NAT rules, and `airgap.sh close` had set them once, at runtime. Pods on it still could not resolve, since their DNS is CoreDNS's or their own namespace's, but the node's own processes and anything on its host network could. Hence the unit at boot.
- [40109411614](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/40109411614): with the node closed at boot, it never came back Ready. The kubelet dials the API server by the control plane's name, and only Docker's resolver answered for it. That was true after every `close`: a kubelet that had to dial again would have found nothing. Hence the two names in the hosts file. The same run lost the gateway's one controller with the node. The proxy left on the other worker learned of no endpoint change and kept sending a share of the requests to a model server that was gone: 503 for 34 of 184 requests, to the end of the window. In the first run the controller had been on the worker that stayed. Hence two controllers.
- [40158438634](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/40158438634): all 24 checks passed.

| In run 40158438634 | Measured |
|---|---|
| The API server saw the lost worker not ready | 51 s after it was killed |
| A model nobody signed, while the worker was lost | refused 87 of 87 times |
| The signed model, while the worker was lost | refused 4 of 87 times, between 11 s and 48 s after the loss |
| Requests through the gateway, the four minutes from the loss | 250 of 258 answered; 8 not, the last 44.8 s after the loss; the longest wait between two answers 53.8 s |
| The worker back, and the boundary on it | ready 2 s after it was started; no outside name resolved by the node or by a pod with the node's resolver, nothing opened to 1.1.1.1 |
| A worker drained under the same traffic | drained in 62 s; 320 of 320 requests answered, the longest wait between two answers 1.5 s; admission never stopped, 107 tries each way |

The first run, with one gateway controller on the worker that stayed, measured the same: 8 of 258 not answered, the longest wait 53.3 s, the signed model refused 4 of 87 times.

**What two replicas buy, and what they do not.** A drain is a non-event: the budgets let one replica go at a time, the model server finishes the answer it is writing before it stops (its `preStop` wait, from the game day's rollout case, `manifests/inference/llama.yaml`), and every request is answered. A crash is not. For about as long as the API server takes to see the node gone, 51 s here, the lost node's pods stay in their Services, and a share of every new connection goes to a pod that no longer exists. The gateway's proxy, the model server and Kyverno's webhook each lose that share. Admission fails closed through it: what it could not check, it refused. That window is the cluster's node lifecycle, not the application's. What shortens it is in the callers: a short connect timeout and a retry on another endpoint, in the agent's harness and in the gateway's backend policy. That is the next step, measured against these numbers.

## Consequences

- One more job in the daily e2e, about 30 minutes on a runner with three kind nodes.
- On AWS, an `ha` run pays for a second m7i.xlarge for the whole run, about $0.20 an hour, and for the minutes the node group takes to replace the one it loses.
- Every kind cluster here now carries the unit and the two hosts entries, whether or not a node is ever restarted.
- CoreDNS keeps its own two replicas, wherever the scheduler puts them; the drill records where they ran.
- The control plane is not tested here: kind's is one container, and EKS's is AWS's.

## Alternatives

- **Disruption budgets alone.** They make a drain safe and do nothing for a crash, which ignores them.
- **A shorter node-monitor grace period.** A flag on the control plane. EKS does not expose it, and on kind it makes a slow node flap and evict what it runs.
- **Three replicas of each.** Losing one node of two already leaves one of each; a third replica buys a second loss, which a two-node cluster cannot survive anyway.

## How to explain this to a customer

We take a server away while the assistant is working, the way a crash would, and the way your maintenance window would. In a crash, for the less than a minute your cluster takes to notice, a few requests fail, and anything that should be refused still is. In maintenance, nothing fails at all. And the server that comes back comes back inside the same closed network. We run it every day, and we publish the seconds.
