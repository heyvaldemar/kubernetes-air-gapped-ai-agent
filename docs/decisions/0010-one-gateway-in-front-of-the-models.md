# 10. One gateway in front of the models

- Status: accepted
- Date: 2026-10-18

## Context

So far each run served one model to one agent, and the agent called the model server directly. A site rarely stops there. Two teams want two models; a third wants the same model with a ceiling on what it may spend; the security review asks where all of it is counted. Wiring each client to each model server answers none of that, and every new pairing is a new hole in the network policies.

The Gateway API Inference Extension is the Kubernetes answer for many replicas of one model: an InferencePool, and an endpoint picker that reads each server's queue. Its endpoint picker, now llm-d-router 1.0.0, reads vLLM's metrics and has no built-in configuration for llama.cpp, and with one replica per model it would have nothing to pick between.

## Decision

- **agentgateway 1.6.0**, a conformant implementation of the Gateway API and of the inference extension, installed from its charts and pinned with them in `gateway/gateway.lock`: the charts and the Gateway API CRDs by sha256, the controller and proxy images by digest. They cross into the boundary in the same signed bundle as everything else (ADR 8).
- **Routing by the model the request names.** Before routing, a policy copies `model` from the request body into a header, the expression agentgateway documents for this; an HTTPRoute sends each name to its own model server. A name with no route is refused at the gateway.
- **A limit per client, at the gateway, with nothing outside it.** Three requests a minute for each `x-client-id`, counted in the proxy; the fourth is refused with 429 and the next client is still served.
- **The gateway is the only way in.** In the gateway job the agents' own rule to the model servers is removed, and their default-deny leaves them the gateway alone. The model servers still have no egress.
- **No endpoint picker yet.** It adds pods, a custom metrics mapping for llama.cpp and a scrape of every server every 50 ms, and does nothing with one replica per model. It goes in with the first model that runs more than one.

## Consequences

- A separate e2e job, "Two models, one gateway", proves it daily from the same bundle: each model answers to its own name (each server reports its `--alias`, so a misrouted request says so), an unknown name is refused with 404, a client's fourth request in a minute gets 429 while another client is served, the model servers cannot be reached around the gateway, and the proxy's request counter records the 429.
- The proxy runs under the restricted Pod Security profile. The Deployment the controller generates sets everything that profile asks but a seccomp profile; an `AgentgatewayParameters` overlay on the Gateway adds it. The first run found it: the namespace refused every proxy pod.
- The six-model evals still call each model server directly, so their cost per task is read from the server's own timings, unchanged. Moving the agent behind the gateway is the next step, once the gateway has run daily.
- A limit by requests, not tokens: token limits need the gateway to read usage from every answer, and that is the step after.

## Alternatives

- **Envoy Gateway.** Its local rate limit counts requests and cannot key on a header per client without a Redis-backed global limit.
- **Istio.** Supports the inference extension, and brings a control plane far larger than the problem.
- **NGINX Gateway Fabric.** Routing by model needs an external processor.
- **A small proxy of our own.** Fewer moving parts, and nothing a platform team would recognise or maintain.

## How to explain this to a customer

All your AI traffic goes through one door. A request says which model it wants and goes to that model; a request for a model you have not approved is turned away at the door. Each team has its own allowance, and one team running hot does not slow the others. Nothing reaches a model server except through that door, and the door counts everything that passes.
