# 11. The gateway knows who is calling

- Status: accepted; amended by [ADR 12](0012-a-token-budget-per-caller.md), which adds a token budget beside each quota and routes every model through a model backend
- Date: 2026-10-19

## Context

ADR 10 put one gateway in front of the models and gave each client three requests a minute, counted per `x-client-id`. That header is written by the caller. Any workload in the agents namespace could write another's name and spend its allowance, or a new name on every request and never meet a limit. A quota anyone can pick is not a control.

The agent's own evals still went around the gateway, straight to the model server. The one client the architecture exists for was the one client the gateway never saw.

## Decision

- **The caller's identity is a service account token the cluster signs.** The agent's pod gets a projected token for the gateway's audience, `models.boundary.heyvaldemar.com`, valid for an hour and rotated by the kubelet; the agent reads it for every request. Nothing is created, handed out or stored: the cluster already issues these tokens, and the agent already holds one for the MCP server's audience the same way (ADR 6).
- **Checked offline, at the gateway.** `scripts/gateway.sh install` reads the cluster's issuer and public keys from the API server's discovery endpoints (`/.well-known/openid-configuration`, `/openid/v1/jwks`) and writes them into the policy. The gateway checks a token's signature, issuer, audience and expiry itself, with nothing to fetch at request time.
- **Strict.** No token is 401. A token for another audience is 401, the pod's own Kubernetes API token included: a credential for one service is not a key to another. The gateway drops the token once it has checked it (agentgateway's default, `preserveToken: false`), so the model server is not handed it.
- **Quotas keyed on the token's subject.** `system:serviceaccount:agents:support-agent` gets 60 requests a minute; any other workload 3. The 60 is measured: in run 39185861415 the agent's busiest minute was 28 model requests (Granite-4.0-1B), reconstructed from the attempt durations in its log and counting a request per tool call plus one per attempt, so an upper bound. Sixty is about twice that.

  *Amended 2026-10-20:* 100. The harness now counts its own busiest minute, every answer's time rather than a reconstruction, and the reconstruction above was not an upper bound: Granite-4.0-1B's busiest minute was 48 answers, and 49 with the tools' patterns hidden (branch run 39458328273). Claude Haiku 5.5, through the gateway to Anthropic's API (ADR 14), reached 50 (run 39473093500). Sixty left the agent a fifth to spare; one hundred is about twice the busiest measured minute again.
- **The evals go through the gateway, in every model job.** Each job installs the gateway and one route to its one model server, and removes the agents' own rule to the model server, as the gateway job already did. One `HTTPRoute` per model server, from `manifests/gateway/route.yaml`; the policies attach to the Gateway and cover every route.
- **The gateway's count is a gate.** The harness counts the model requests it makes; the proxy counts the requests it passed to a model server. The two must be equal, and the proxy must have refused none of the agent's requests over its quota.

## Consequences

- The first full run on the branch (39196040348) passed in all seven jobs. In each of the six model jobs the agent's count and the gateway's matched, from 80 requests (Qwen3-4B-Instruct-2507) to 117 (Granite-4.0-1B), and none was refused over the quota; the gateway job passed all eleven of its checks.
- The gateway job proves the identity daily: no token, and a token for the Kubernetes API, are each refused with 401; a workload's fourth request in a minute is refused with 429, and writing `x-client-id: support-agent` into its request does not lift that; another workload, right after, is served; the support agent's four in a row are all served.
- Static check `gateway`: the policy requires a token (mode Strict) for a named audience, the evals Job holds a token for that audience, and every quota is keyed on `jwt.sub`. Each has a planted violation: a quota keyed on a header, `mode: Optional`, an agent token for another audience.
- The keys are a snapshot. When the cluster rotates its service account signing key, `scripts/gateway.sh install` runs again. On kind the key lives as long as the cluster. On a site that rotates it, the policy's `jwks.remote` pointed at the API server's key set is the change, at the cost of the gateway calling the API server every five minutes.
- Any workload in the cluster can ask for a token for the gateway's audience. What it gets is the default quota under its own name, never the agent's.
- Cost per task is still the model server's own compute time: the gateway passes the server's answer through unchanged, `timings` included.
- A limit by requests, still. agentgateway can also limit tokens per minute, counted only once an answer completes, so a token limit applies to the next request. That is the next step.

## Alternatives

- **Keep the header and trust the namespace.** Every workload in it can write any header.
- **API keys at the gateway.** A secret per client to create, hand out, rotate and revoke, where the cluster already issues an identity that expires within the hour.
- **A TokenReview per request.** What the MCP server does (ADR 6). At the gateway it is a call to the API server on every model request; checking the signature against the cluster's keys is local.
- **Mutual TLS identity from a mesh.** Stronger, and it needs Istio's ambient mode or similar under every workload, far larger than the problem here.

## How to explain this to a customer

Every program that asks a model for an answer shows a pass the cluster issued to it, good for an hour. The door checks the pass itself, without calling anyone, and turns away anyone without one, or with a pass meant for somewhere else. Allowances belong to the pass, not to a name written on the request, so one program cannot spend another's. Your support assistant has its own allowance, sized from what it actually used, with room to spare, and the door's own count has to match the assistant's, request for request.
