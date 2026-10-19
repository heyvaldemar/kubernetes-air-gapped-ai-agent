# 12. A token budget per caller

- Status: accepted
- Date: 2026-10-19

## Context

ADR 11 holds each caller to a number of requests a minute: 60 for the support agent, 3 for any other workload. A request is not what a model server spends. On a CPU it spends time per token, and one request can carry ten times the tokens of another: in run 39280471778 the agent's attempts on Qwen3.5-2B ranged up to 5,898 tokens each, and a workload inside its three requests could send three prompts that long or longer. A quota in requests caps how often a caller asks, not how much it costs.

agentgateway 1.6.0 can also limit tokens a minute, per key (`rateLimit.local[].tokens`). Added to the routes as they were, straight to each model's Service, the budget was accepted and reported as attached, and refused nothing: the gateway reads an answer's usage only on a route to a backend that says it is a model, an `AgentgatewayBackend` with an `ai` provider. To a plain Service it passes bytes and counts no tokens. agentgateway's inference routing page says so; the policy's status does not. The proof run on the branch shows it (Consequences).

## Decision

- **Every model server is an `AgentgatewayBackend`.** One per model, in `inference` beside its Service, the one namespace it may name a Service in: a custom provider whose `backendRef` is the Service, speaking the OpenAI chat completions format. Each `HTTPRoute` (`manifests/gateway/route.yaml`) points at that backend, never at the Service. The `ReferenceGrant` in `inference` now lets routes in `gateway` name these backends, and no longer Services.
- **A budget per service account, beside the quota, keyed the same way.** `system:serviceaccount:agents:support-agent` may spend 60,000 tokens a minute, any other workload 1,000, keyed on the token's subject like the quota. Input and output both count. The 60,000 is measured: across three green runs on main (39199529930, 39235439268, 39280471778) the agent's busiest minute was at most about 29,000 tokens, Qwen3.5-2B in run 39199529930, reconstructed from each attempt's tokens and duration in its log with the tokens spread evenly over the attempt. Sixty thousand is about twice that.
- **Settled after the answer.** A token count is known only once the answer is complete, so the request that crosses a budget is served and the next one is refused with 429. The harness caps an answer at 400 tokens, which bounds the agent's overshoot to one prompt and 400.
- **The answer is unchanged.** The backend reads the answer's `usage` and passes the answer on as the server wrote it, `timings` included, so the harness's cost per task still comes from the server's own compute time. Checked before the change on a local kind cluster with the pinned charts, against a stand-in server that returned `timings` and a tool call: both came back the same through a route to the Service and through the backend. In CI, every model job's cost per task is read from those timings and would fall to zero without them.
- **The gateway's count follows.** Requests through a model backend are counted under `backend="inference/<service>"` and `protocol="llm"`, not the Service's address; the gate that the gateway answered every request the agent made reads those labels. A second gate counts tokens the same way: the gateway's input plus output must equal the agent's own count, prompt (cached or not) plus answer. The gateway also reports the cached part of the input as a series of its own, `input_cache_read`; added to the rest it counts those tokens twice, and the first version of this comparison did exactly that.

## Consequences

- The full run on the branch, 39335646130, passed in all seven jobs. In each model job the gateway's token count equalled the agent's to the token, from 47,001 (Ministral-3-3B) to 87,723 (Qwen3.5-2B), and none of the agent's requests was refused. Summed with `input_cache_read`, the same counts were off by exactly the cached tokens in all six jobs, about 1.9 times the agent's: the failure the gate exists for, a count that is not the agent's.
- The gateway job proves the budget daily: a workload sends one request of about 1,500 tokens, which is served, and its next request, only its second of the minute and so under its request quota, is refused with 429; the support agent's same long request is served. The proxy's own token counter must show tokens for each of the two models.
- Static check `gateway`: every caller with a request quota has a token budget, and every route goes to an `AgentgatewayBackend`. Two plants: a route straight to the Service, and a caller with a quota and no budget.
- Budgets are counted in each proxy replica on its own. There is one replica here. A site running several gives each caller the full budget in every replica; the global rate limit service is the change.
- The budget counts what the server reports as usage, cached prompt tokens included, so it is a ceiling on tokens, not on compute: a long prompt the server has cached costs it little and counts in full.
- A workload that needs more asks for it by name: its own rule in the policy, keyed on its own subject.

## Alternatives

- **Only the request quota.** It caps how often, and a caller choosing long prompts spends what it likes inside it.
- **A cap on `max_tokens` at the gateway.** It bounds one answer, not a caller's minute, and leaves the prompt, often the larger part, unbounded.
- **A limit on the model server.** llama.cpp does not know who is calling; the identity is at the gateway (ADR 11).
- **The global rate limit service.** The right tool for several gateway replicas, and one more service inside the boundary for one.

## How to explain this to a customer

Allowances were counted in requests, and a request is not what costs you: one long question can cost the model as much as fifty short ones. Each program now also has an allowance in tokens, the unit the model works in, sized from what your assistant actually used, with room to spare. A program that spends its allowance waits for the next minute, and everyone else is still served. The gateway counts every token itself, and its count has to equal the assistant's own, token for token.
