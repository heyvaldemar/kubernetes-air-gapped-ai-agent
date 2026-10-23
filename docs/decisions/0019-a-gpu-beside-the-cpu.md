# 19. A GPU beside the CPU: the same model, the same weights, measured side by side

- Status: proposed; the first AWS run with a GPU decides
- Date: 2026-10-22

## Context

The repository serves its models on CPU (ADR 4) and sizes a server by measurement: on four vCPUs, Granite-4.0-1B answers about 45 of the agent's calls a minute, and parallel slots add nothing, because they split the same cores (README, Sizing). On AWS the same model on an m7i.xlarge answered at half the runner's rate (ADR 18). The question a buyer asks next is what a GPU changes, and at what price per call, inside the same boundary.

The account's quota for G and VT instances was 0. AWS raised it to 8 vCPUs on 2026-10-22 after an appeal that described this test: one g6.xlarge, about an hour a week, under $5 a month, inside the $30 kill-switch.

## Decision

- **The same model, the same weights, the same engine.** The GPU server mounts the CPU server's signed model image by the same digest, verified by the same admission, and runs the CUDA build of the same llama.cpp release (b11429). Only the hardware differs, so the difference measured is the hardware's.
- **Inside the same boundary.** One g6.xlarge (one NVIDIA L4) in the same private subnets, on EKS's AL2023 NVIDIA image, tainted so only what asks for a GPU lands on it. The CUDA image and NVIDIA's device plugin cross in the same signed bundle, pinned to their linux/amd64 manifests (`airgap/images-gpu.txt`), seeded only when a run asks for a GPU.
- **Measured with the agent's own calls.** `scripts/capacity.py` against both servers at concurrency 1, 2, 4 and 8: calls a minute, p50 and p95, output tokens a second, and what a thousand calls cost at each node's list price. The CPU server as the evals run it (one slot, two threads); the GPU server with eight slots, since on a GPU requests in flight are batched.
- **Checked like everything else** (`scripts/gpu.sh check`): the node offers one GPU; the GPU server runs on it with the CPU server's model digest; every layer is on the GPU; a pod asking for the GPU with weights nobody signed is refused.
- **By hand first** (`gpu: true` on a dispatch), weekly once a run has passed (`AWS_GPU_ENABLED`).

## Consequences

- About $1 more for a run with a GPU: a g6.xlarge at $0.8048 an hour beside the rest. Weekly, about $4 a month, within the $15 the maintainer set for GPU work.
- The bundle grows by 2.6 GB on a GPU run, and the runner frees disk for it as the kind e2e does.
- The device plugin runs in its own namespace at the privileged Pod Security level, which reading the kubelet's device-plugin socket needs; its image is held to what the bundle carried like any other.

## Alternatives

- **vLLM on the GPU.** The usual server for GPU serving, and the one the quota appeal named. It reads weights in another format, so the GPU would serve different files from the ones signed and attested for the CPU, and the comparison would measure two engines and two files at once. The CUDA build of the same llama.cpp keeps everything but the hardware equal.
- **A GPU node every week from the start.** The first run by hand says what it costs and what it shows before it becomes a standing line in the account's bill.

## How to explain this to a customer

We run the same signed model on an ordinary server and on one with a GPU, inside the same closed network, and measure both with the requests your agent actually makes: how many answers a minute, how long each takes, and what a thousand of them cost. Then you choose the hardware from numbers, not from a vendor's benchmark.
