# 19. A GPU beside the CPU: the same model, the same weights, measured side by side

- Status: accepted, 2026-10-23
- Date: 2026-10-22

## Context

The repository serves its models on CPU (ADR 4) and sizes a server by measurement: on four vCPUs, Granite-4.0-1B answers about 45 of the agent's calls a minute, and parallel slots add nothing, because they split the same cores (README, Sizing). On AWS the same model on an m7i.xlarge answered at half the runner's rate (ADR 18). The question a buyer asks next is what a GPU changes, and at what price per call, inside the same boundary.

The account's quota for G and VT instances was 0. AWS raised it to 8 vCPUs on 2026-10-22 after an appeal that described this test: one g6.xlarge, about an hour a week, under $5 a month, inside the $30 kill-switch.

## Decision

- **The same model, the same weights, the same engine.** The GPU server mounts the CPU server's signed model image by the same digest, verified by the same admission, and runs the CUDA build of the same llama.cpp release (b11429). Only the hardware differs, so the difference measured is the hardware's.
- **Inside the same boundary.** One g6.xlarge (one NVIDIA L4) in the same private subnets, on EKS's AL2023 NVIDIA image, tainted so only what asks for a GPU lands on it. The CUDA image and NVIDIA's device plugin cross in the same signed bundle, pinned to their linux/amd64 manifests (`airgap/images-gpu.txt`), seeded only when a run asks for a GPU.
- **Measured with the agent's own calls.** `scripts/capacity.py` against both servers at concurrency 1, 2, 4 and 8: calls a minute, p50 and p95, output tokens a second, and what a thousand calls cost at each node's list price. The CPU server as the evals run it (one slot, two threads); the GPU server with eight slots, since on a GPU requests in flight are batched.
- **From inside the cluster, for long enough.** A Job beside the servers, in a namespace of its own whose one door into inference is for its pod, on the servers' port, for the minutes it runs (`manifests/gpu/measure.yaml`); closed after and checked closed. Each level lasts at least 30 seconds and starts with one untimed round. The first runs measured from the runner, through a port-forward, six calls a level; see the spread below. The GPU is measured that way once more in each run, beside the runner's time to the EKS API, so the path's share of a call stays on record.
- **Then a larger model on the same GPU.** Granite 4.1 at 8B parameters (Apache-2.0, a 5.0 GiB file), built, signed and attested like the default and carried in the same bundle on GPU runs. Once the first model is measured its server goes, since a pod holds the GPU whole, and the larger one is served, checked on its digest and in the GPU's memory, measured the same way, and run through the evals with everything they read started afresh: the task floor off, as for every model in the matrix, and every other gate on.
- **Checked like everything else** (`scripts/gpu.sh check`): the node offers one GPU; the GPU server runs on it with the CPU server's model digest; the model is in the GPU's memory, by `nvidia-smi` in the server's container; a pod asking for the GPU with weights nobody signed is refused.
- **The GPU node for the minutes it is measured.** The run's first apply makes no GPU node. After the evals, the game day and the CPU server's measurement, a second apply adds it; a third takes it away as soon as it is measured, whatever happened, and the cost table prices it between the two.
- **By hand first** (`gpu: true` on a dispatch), weekly once a run has passed (`AWS_GPU_ENABLED`, on from 2026-10-23).

## On AWS, 2026-10-23

- [39893082349](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39893082349): the GPU worked and the check failed. The node offered its GPU, the server ran the CPU server's model digest on it, and a pod with weights nobody signed was refused; but the check that every layer was on the GPU read a log line llama-server b11429 no longer prints. It asks the GPU now, with `nvidia-smi` in the server's container.
- [39898005905](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39898005905): all 63 checks passed, and the run is red for its residue check after the destroy, which found `subnet-06db67a9c28931a7c` under the run's cluster tag. EC2 has no such subnet, and CloudTrail names no event for it; the run's one refused CreateSubnet, throttled with `RequestLimitExceeded` at 04:06:42 and made two seconds later as another subnet, carried that tag. The residue check asks EC2 about a subnet before it counts one now. The L4 held 6,370 MiB of its 23,034 MiB. The agent's own first calls, through a port-forward to each server:

| On | Slots x threads | Concurrency | Calls a minute | p50 | p95 | Output tokens/s | A thousand calls |
|---|---|---|---|---|---|---|---|
| CPU, m7i.xlarge | 1 x 2 | 1 | 29.4 | 2.31 s | 2.48 s | 9.6 | $0.114 |
| CPU, m7i.xlarge | 1 x 2 | 8 | 31.5 | 15.22 s | 16.27 s | 10.9 | $0.107 |
| GPU, g6.xlarge (L4) | 8 x 0 | 1 | 224.3 | 0.29 s | 0.29 s | 72.9 | $0.060 |
| GPU, g6.xlarge (L4) | 8 x 0 | 2 | 378.9 | 0.32 s | 0.34 s | 127.9 | $0.035 |
| GPU, g6.xlarge (L4) | 8 x 0 | 4 | 564.6 | 0.41 s | 0.48 s | 198.8 | $0.024 |
| GPU, g6.xlarge (L4) | 8 x 0 | 8 | 756.0 | 0.62 s | 0.72 s | 263.0 | $0.018 |

On the GPU the slots batch: eight callers got 3.4 times the calls a minute one caller got, each answered in well under a second. On the CPU the server queued: 30 calls a minute whatever the concurrency, the wait growing with the queue. A thousand calls, at each node's on-demand list price for the time it took, cost less on the GPU at every concurrency measured, though the node costs four times as much an hour: it answered 7.6 to 24 times as many. The CPU server ran as the evals run it, one slot on two of the node's four vCPUs; with four threads the runner measured about 45 calls a minute (README, Sizing), which does not change the order.

That run kept the GPU node up from the first apply, so $0.98 of the run's $1.49 was the GPU's. [39905417932](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39905417932) made it after the evals and kept it to the destroy: 0.93 h of the run's 1.41, all checks passed, $1.34. From there it exists only around its own measurement: [39914708816](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39914708816), all 63 checks, the GPU node up 0.32 h of 1.03, the run about $0.69.

The two runs did not measure the same GPU. With one caller it served 224 calls a minute at a p50 of 0.29 s in 39898005905 and 418 at 0.16 s in 39914708816; with eight, 756 and 972. The CPU held at 29 to 32 both times. The workload was the same in both, 509 prompt tokens and about 20 out a call, and every level on the GPU was 0.09 to 0.13 s a call slower in the first. One thing that differs between runs is the path each call takes: from the GitHub runner, through the EKS API's port-forward, to the pod, which at these latencies is a real part of each call. The order holds in both runs, and so does the price per call.

## On AWS, 2026-10-24

[40052214040](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/40052214040): all 80 checks passed, the residue check found nothing of the run and nothing of any earlier run, and the run cost about $1.16 for 1.51 h, the GPU node 0.65 h of it ($0.52). Every server was measured from a pod beside it, each level for at least 30 seconds; the default model's GPU server once more through a port-forward from the runner, whose TCP connect to the EKS API took 95 ms (the median of ten).

| Model | On | Measured from | Concurrency | Calls a minute | p50 | p95 | Output tokens/s | A thousand calls |
|---|---|---|---|---|---|---|---|---|
| granite-4.0-1b | CPU, m7i.xlarge, 1 slot x 2 threads | the cluster | 1 | 31.8 | 2.01 s | 2.23 s | 10.9 | $0.106 |
| granite-4.0-1b | CPU, m7i.xlarge, 1 slot x 2 threads | the cluster | 8 | 32.2 | 14.82 s | 15.84 s | 11.2 | $0.104 |
| granite-4.0-1b | GPU, g6.xlarge (L4), 8 slots | the cluster | 1 | 402.1 | 0.16 s | 0.16 s | 140.0 | $0.033 |
| granite-4.0-1b | GPU, g6.xlarge (L4), 8 slots | the cluster | 2 | 599.6 | 0.21 s | 0.23 s | 209.2 | $0.022 |
| granite-4.0-1b | GPU, g6.xlarge (L4), 8 slots | the cluster | 4 | 816.1 | 0.31 s | 0.35 s | 285.4 | $0.016 |
| granite-4.0-1b | GPU, g6.xlarge (L4), 8 slots | the cluster | 8 | 1028.6 | 0.49 s | 0.56 s | 359.4 | $0.013 |
| granite-4.0-1b | GPU, g6.xlarge (L4), 8 slots | a port-forward from the runner | 1 | 167.2 | 0.35 s | 0.41 s | 58.3 | $0.080 |
| granite-4.0-1b | GPU, g6.xlarge (L4), 8 slots | a port-forward from the runner | 8 | 701.3 | 0.71 s | 0.82 s | 244.8 | $0.019 |
| granite-4.1-8b | GPU, g6.xlarge (L4), 8 slots | the cluster | 1 | 85.1 | 0.55 s | 2.13 s | 42.1 | $0.158 |
| granite-4.1-8b | GPU, g6.xlarge (L4), 8 slots | the cluster | 2 | 153.0 | 0.67 s | 1.82 s | 68.9 | $0.088 |
| granite-4.1-8b | GPU, g6.xlarge (L4), 8 slots | the cluster | 4 | 230.6 | 0.88 s | 2.43 s | 101.7 | $0.058 |
| granite-4.1-8b | GPU, g6.xlarge (L4), 8 slots | the cluster | 8 | 263.6 | 1.55 s | 4.08 s | 114.5 | $0.051 |

**The spread was the path.** From inside the cluster the L4 served 402 calls a minute with one caller at a p50 of 0.16 s, what 39914708816 measured through its port-forward. Through a port-forward in this run it served 167 at 0.35 s, and every level was 0.19 to 0.33 s a call slower that way. The earlier runs did not record the runner's distance to the API; 39898005905's 0.29 s fits a runner nearer than this one's, and 39914708816's 0.16 s a runner next to it. The numbers to read are the ones from inside the cluster, and every run measures that way from here.

**From inside, the gap is wider.** With one caller the GPU answered 12.6 times the CPU's calls, with eight 32 times, and a thousand calls cost $0.013 on it against $0.104 on the CPU. The CPU server still held at 32 calls a minute whatever the concurrency, the wait growing with the queue.

**A larger model on the same GPU.** Granite 4.1 at 8B parameters, mounted from its own signed image by digest, held 15,460 MiB of the L4's 23,034. It answered 85 calls a minute with one caller at a p50 of 0.55 s and 264 with eight at 1.55 s: a fifth of the 1B's rate with one caller and a quarter with eight, $0.158 to $0.051 a thousand calls. It writes more a call, 26 to 30 output tokens against 21, and its p95 is 2.6 to 3.9 times its p50. Through the evals, with everything they read started afresh, every gate held: every attempt finished, nothing was delivered outside, nothing deleted, every request and every token counted at the gateway, and its busiest minute was 55 answers, inside the agent's quota of 100. Beside the default model's evals in the same run, on the CPU:

| In the same run | granite-4.0-1b, CPU | granite-4.1-8b, GPU |
|---|---|---|
| Tasks done | 18 of 18 | 18 of 18 |
| Planted instructions acted on | 6 of 21, both in the quarterly report (3/3, 3/3) | 6 of 21, both in the quarterly report (3/3, 3/3) |
| Requests beyond the agent's rights it declined | 0 of 9 | 3 of 9 |
| Answers without invented data | 3 of 6 | 6 of 6 |
| Acting for a person, within that person's rights | 10 of 12 | 12 of 12 |
| Consistent across all 3 attempts | 15 of 22 tasks | 17 of 22 tasks |
| Latency per task, p50 | 5.3 s | 2.6 s |
| Cost per task | about $0.00017 (vCPU-seconds) | about $0.00043 (1.92 s of the g6.xlarge) |

The larger model was fooled by the same planted report as the small one, every time, and its gates held because the boundary held, as they did for the small one. It was better at what is the model's own job: declining what the agent may not do, not inventing data, staying inside the rights of the person it acts for. It costs two and a half times as much a task on a node that costs four times as much an hour, and answered in half the time.

## Consequences

- A g6.xlarge at $0.8048 an hour for the part of the run it exists: the second apply, the device plugin, the server, the checks and the measurement, then the destroy. Weekly, within the $15 a month the maintainer set for GPU work.
- For a model this small at low traffic the CPU node is still the smaller bill, $0.20 an hour against $0.80; the GPU is the cheaper call once there are calls to batch.
- The bundle grows on a GPU run by 2.6 GB for the CUDA image and 5.0 GiB for the larger model, to 11 GB against 6.0 (run 40052214040), and the runner frees disk for it as the kind e2e does. Its signature is over its sha256 (ADR 8): cosign holds a blob it signs in memory at about twice its size, and run 40048612675 was killed signing this one.
- The larger model's weights and its cache take 15,460 MiB of the L4's 23,034; the default model's server goes first, since a pod holds the GPU whole, and the GPU node is up for 0.65 h of a 1.5 h run.
- The device plugin runs in its own namespace at the privileged Pod Security level, which reading the kubelet's device-plugin socket needs; its image is held to what the bundle carried like any other.

## Alternatives

- **vLLM on the GPU.** The usual server for GPU serving, and the one the quota appeal named. It reads weights in another format, so the GPU would serve different files from the ones signed and attested for the CPU, and the comparison would measure two engines and two files at once. The CUDA build of the same llama.cpp keeps everything but the hardware equal.
- **A GPU node every week from the start.** The first run by hand says what it costs and what it shows before it becomes a standing line in the account's bill.

## How to explain this to a customer

We run the same signed model on an ordinary server and on one with a GPU, inside the same closed network, and measure both with the requests your agent actually makes: how many answers a minute, how long each takes, and what a thousand of them cost. Then you choose the hardware from numbers, not from a vendor's benchmark.
