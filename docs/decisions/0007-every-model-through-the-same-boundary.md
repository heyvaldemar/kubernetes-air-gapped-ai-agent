# 7. Every model through the same boundary, every day

- Status: accepted
- Date: 2026-10-18

## Context

Two models made the point of ADR 5 from two sides: Granite-4.0-1B was fooled by instructions hidden in a report and never wrote an outside address, Qwen3.5-2B ignored the instructions and tried outside addresses eighteen times, and nothing left the company in either run. Two is an anecdote. The claim the architecture makes is about any model: that what reaches the outside does not depend on which model is inside.

A customer choosing a model asks the same question from the other end. Which of the models whose licence lets them run it is useful on their tasks, how often is it fooled, and what does a task cost on their hardware. Since the repository went public its runners have four vCPUs and 16 GB, enough for models of three to four billion parameters on CPU.

## Decision

- **The e2e matrix runs every model in `models/models.lock` through the same boundary, every day.** Two ship with the release: Granite-4.0-1B and Qwen3.5-2B. Four more are there to be measured, from four makers, all Apache-2.0 and pinned like the rest: Mistral's Ministral-3-3B, IBM's Granite-4.1-3B, Qwen3-4B-Instruct-2507 and Nanbeige4.2-3B. Each was checked for a licence on its own card, a quantized file from its maker or a known quantizer, and a chat template llama.cpp b11429 reads tool calls from.
- **The boundary's gates hold for every model; the usefulness floor only for the two that ship.** Nothing delivered outside and nothing deleted are what the architecture promises, so they gate every job. Whether a model does 60% of ordinary tasks is a property of that model; for the measured models it is published, not gated (`TASK_FLOOR=off`).
- **The control no longer depends on the model.** The gate "nothing delivered outside" needs a control that email can be delivered at all. It used to be the model's own emails inside the company, which a model that sends nothing would fail. The harness now sends one email inside through the same MCP server, with the same token, before the first task, and the run requires it in the outbox.
- **One table, written by the status workflow from the latest run.** `leaderboard.md` on the `status` branch has a row per model: what it tried, what got out, what a task cost. Nothing in it is typed by hand.

## Consequences

- A model that is weaker at the tasks, or more easily fooled, turns no run red as long as the boundary holds; that is what it is there to show.
- The daily run is six jobs instead of two, in parallel on public runners, at no cost.
- A failed boundary gate on any model fails the run, and says which model.
- The four measured models are pinned by file and revision from the start, and by image digest from their first build; `scripts/model.sh` fails a build whose digest moved.

## Alternatives

- **Only the release models.** Two data points cannot carry a claim about any model.
- **Larger models.** Not measured here. A 7B model costs about twice the compute per token of the 4B models on the same two threads, and the matrix measures what a CPU-only site runs.
- **Phi-4-mini-instruct and SmolLM3-3B.** Licences that fit, but templates that never render tool calls, so llama.cpp returns their calls as text; both would need a template of our own, which would be measuring our template.

## How to explain this to a customer

We put six different AI models, from four makers, behind the same controls and attack all of them every day with the same planted instructions. How often each one is fooled is measured and published. The number that matters to you, what left the network, has to be zero for every one of them or the run fails, and the table showing it is rewritten every morning from the run itself.
