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
- **Checked like everything else** (`scripts/gpu.sh check`): the node offers one GPU; the GPU server runs on it with the CPU server's model digest; the model is in the GPU's memory, by `nvidia-smi` in the server's container; a pod asking for the GPU with weights nobody signed is refused.
- **The GPU node for the minutes it is measured.** The run's first apply makes no GPU node; a second apply after the evals adds it, and the cost table prices it from that apply.
- **By hand first** (`gpu: true` on a dispatch), weekly once a run has passed (`AWS_GPU_ENABLED`).

## On AWS, 2026-10-23

- [39893082349](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39893082349): the GPU worked and the check failed. The node offered its GPU, the server ran the CPU server's model digest on it, and a pod with weights nobody signed was refused; but the check that every layer was on the GPU read a log line llama-server b11429 no longer prints. It asks the GPU now, with `nvidia-smi` in the server's container.
- [39898005905](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39898005905): all 63 checks passed. The L4 held 6,370 MiB of its 23,034 MiB. The agent's own first calls, through a port-forward to each server:

| On | Slots x threads | Concurrency | Calls a minute | p50 | p95 | Output tokens/s | A thousand calls |
|---|---|---|---|---|---|---|---|
| CPU, m7i.xlarge | 1 x 2 | 1 | 29.4 | 2.31 s | 2.48 s | 9.6 | $0.114 |
| CPU, m7i.xlarge | 1 x 2 | 8 | 31.5 | 15.22 s | 16.27 s | 10.9 | $0.107 |
| GPU, g6.xlarge (L4) | 8 x 0 | 1 | 224.3 | 0.29 s | 0.29 s | 72.9 | $0.060 |
| GPU, g6.xlarge (L4) | 8 x 0 | 2 | 378.9 | 0.32 s | 0.34 s | 127.9 | $0.035 |
| GPU, g6.xlarge (L4) | 8 x 0 | 4 | 564.6 | 0.41 s | 0.48 s | 198.8 | $0.024 |
| GPU, g6.xlarge (L4) | 8 x 0 | 8 | 756.0 | 0.62 s | 0.72 s | 263.0 | $0.018 |

On the GPU the slots batch: eight callers got 3.4 times the calls a minute one caller got, each answered in well under a second. On the CPU the server queued: 30 calls a minute whatever the concurrency, the wait growing with the queue. A thousand calls, at each node's on-demand list price for the time it took, cost less on the GPU at every concurrency measured, though the node costs four times as much an hour: it answered 7.6 to 24 times as many. The CPU server ran as the evals run it, one slot on two of the node's four vCPUs; with four threads the runner measured about 45 calls a minute (README, Sizing), which does not change the order.

That run kept the GPU node up from the first apply, 1.21 h of which it was measured for a fraction, so $0.98 of the run's $1.49 was the GPU's. From here it is made after the evals and priced from then.

## Consequences

- A g6.xlarge at $0.8048 an hour for the part of the run it exists: the second apply, the device plugin, the server, the checks and the measurement, then the destroy. Weekly, within the $15 a month the maintainer set for GPU work.
- For a model this small at low traffic the CPU node is still the smaller bill, $0.20 an hour against $0.80; the GPU is the cheaper call once there are calls to batch.
- The bundle grows by 2.6 GB on a GPU run, and the runner frees disk for it as the kind e2e does.
- The device plugin runs in its own namespace at the privileged Pod Security level, which reading the kubelet's device-plugin socket needs; its image is held to what the bundle carried like any other.

## Alternatives

- **vLLM on the GPU.** The usual server for GPU serving, and the one the quota appeal named. It reads weights in another format, so the GPU would serve different files from the ones signed and attested for the CPU, and the comparison would measure two engines and two files at once. The CUDA build of the same llama.cpp keeps everything but the hardware equal.
- **A GPU node every week from the start.** The first run by hand says what it costs and what it shows before it becomes a standing line in the account's bill.

## How to explain this to a customer

We run the same signed model on an ordinary server and on one with a GPU, inside the same closed network, and measure both with the requests your agent actually makes: how many answers a minute, how long each takes, and what a thousand of them cost. Then you choose the hardware from numbers, not from a vendor's benchmark.
