# 4. Small open-weights models on CPU, chosen by measurement

- Status: accepted
- Date: 2026-10-18

## Context

A model inside the boundary has to run there. GitHub's runners have no GPU: 4 vCPU and 16 GB on a public repository, 2 and 7 on a private one. The question was whether a model that fits can act as an agent at all, calling tools with arguments that parse, before anything was designed around one.

## Decision

- **llama.cpp's `llama-server`**, CPU build, pinned by digest: the smallest image of the candidates (about 310 MB), an OpenAI-compatible API with tool calling, tested tool-call parsers for the model families used here, and Prometheus metrics.
- **Apache-2.0 models only**, pinned by revision and sha256 at Q4_K_M: IBM's Granite-4.0-1B and Qwen3.5-2B. Gated or field-of-use licences (Llama's community licence, LFM's revenue cap) are out.
- **Chosen by a spike on the runner** (`spike/`): ten agent tasks, two of them with an instruction hidden in a tool result, one with a destructive tool in reach. On a 2-vCPU runner both passed all ten; Granite in 88 seconds, Qwen in 128. Both are kept, and the e2e workflow runs the same boundary around each.
- **No fractional CPU limit** on the server: llama.cpp's threads wait at a barrier by spinning, and a throttled thread stalls the rest (llama.cpp#29258). The request is a quarter of a CPU so it schedules beside Kyverno on two cores; the threads take what is idle.

## Consequences

- An agent task costs seconds of CPU, not cents of API: the evals measure it (ADR 5).
- Small models are weak at exactly what a security review asks about: refusing a request beyond their rights, ignoring an instruction hidden in data. The evals measure that too, and the architecture does not lean on it.
- The models and the server are pinned like everything else, so a better model is a change to one lock file, judged by the same evals.

## Alternatives

- **vLLM's CPU backend.** Runs on AVX2 with limited features, does not load GGUF on x86, and its image is 1.6 GB.
- **Ollama.** No `tool_choice`, no Prometheus endpoint, a 3.8 GB image.
- **A hosted frontier model.** Leaves the boundary by definition; a comparison run against one would cost money and needs its own approval.

## How to explain this to a customer

The model runs inside your network on ordinary CPUs, so no customer data goes to an AI provider. It is a small open model whose licence lets you run it commercially, chosen by measuring it on the tasks it will do, and it can be replaced by a better one by changing one line, with the same tests deciding whether it is better.
