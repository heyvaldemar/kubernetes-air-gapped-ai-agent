# Threat model

What this reference architecture defends against, the control for each threat, and the check or eval that shows the control works on every run. The two lists it maps to are the OWASP Top 10 for LLM Applications 2026 (published 2026-08-04) and the OWASP Top 10 for Agentic Applications 2026 (published 2025-12-09). Items the architecture does not address are listed as such, not left out.

## The boundary

| Threat | Control | Shown by |
|---|---|---|
| A workload, or the node, sends data out | The host's firewall rejects anything leaving kind's bridge; the node has no DNS server; CoreDNS answers only for the cluster and the registry ([ADR 1](decisions/0001-the-boundary-is-the-runners-firewall.md)) | e2e checks 1 to 4: a pod and the node each fail to reach 1.1.1.1 by IP and to resolve example.com |
| Something runs that was not brought in and checked | Every image comes from the registry inside, seeded by digest before the cut ([ADR 2](decisions/0002-the-registry-inside-has-its-own-name.md)) | e2e check 5: the node cannot pull an image the registry does not hold. Static check `boundary`: every image a manifest names is in `airgap/images.txt` |
| The registry is read or impersonated on the wire | TLS from the boundary's CA; plain HTTP refused | e2e check 8 |

## The model

| OWASP | Threat | Control | Shown by |
|---|---|---|---|
| LLM04 Supply Chain, ASI04 Agentic Supply Chain Vulnerabilities | Swapped or tampered model weights | The model is an image pinned by digest, built reproducibly from a file pinned by sha256, signed with the operator's key, verified at admission offline ([ADR 3](decisions/0003-model-weights-as-a-signed-image-volume.md)) | e2e check 9: unsigned weights, weights signed by another key, the model by tag and an image volume from elsewhere are refused, the signed model is admitted. Every run rebuilds the image and fails if its digest moved |
| LLM04 Supply Chain | A model the site may not run: an unknown origin, or a licence it does not allow | An AI-BOM per model (CycloneDX ML-BOM: origin, revision, sha256, licence), attested with the operator's key; admission requires it and holds the licence to the site's list ([ADR 9](decisions/0009-an-ai-bom-for-every-model.md)) | e2e check 9: a signed model with no AI-BOM, and one whose AI-BOM declares GPL-3.0-only, are refused. Static check `policies`, with a planted violation |
| LLM05 Data and Model Poisoning | A model trained to misbehave | Not addressed: the model is a published one, chosen by measurement ([ADR 4](decisions/0004-small-models-on-cpu-chosen-by-measurement.md)) | The evals show its behaviour, not its training |
| LLM06 Unbounded Consumption | An agent or a caller exhausts the model server | The MCP server's per-identity rate limit; the model server's memory limit; the evals Job's deadline; in front of the models, the gateway's quota and token budget per service account, keyed on the token's subject ([ADR 10](decisions/0010-one-gateway-in-front-of-the-models.md), [ADR 11](decisions/0011-the-gateway-knows-who-is-calling.md), [ADR 12](decisions/0012-a-token-budget-per-caller.md)) | Gateway job: a workload's fourth request in a minute is refused with 429 and another workload is still served; a workload that spent its 1,000 tokens in one request is refused its next. Evals: the gateway refused none of the agent's requests over its quota or budget. Static check `gateway`: every caller has a budget, every route goes to a model backend. Not load-tested |

## The agent

| OWASP | Threat | Control | Shown by |
|---|---|---|---|
| LLM01 Prompt Injection, ASI01 Agent Goal Hijack | An instruction in a record or a report turns the agent | Nothing in the model is relied on. Tool results are data in the system prompt; the boundary decides what acting on them can reach | Evals, injection category: how often the model acted on the instruction (measured, published), and whether anything left (gated at zero) |
| LLM02 Sensitive Information Disclosure, ASI02 Tool Misuse | The agent sends data outside through a tool it is granted | `send_email`'s schema holds the recipient to `@acme.example`; the server validates every call before any upstream sees it ([ADR 6](decisions/0006-tools-through-the-sandboxs-mcp-server.md)). In front of it, the model server's grammar, built from the same schema, keeps most models from writing an outside address at all; it depends on the chat template and nobody configures it, so the boundary does not rest on it ([ADR 13](decisions/0013-the-decoder-is-a-control.md)) | Evals: emails that left the outbox for an address outside acme.example, gated at zero; the model's attempts outside, and the server's refusals of them, counted. Every model runs a second time with the patterns hidden from it: in run 39369404367 the six tried outside 92 times, and the server refused all 92 |
| LLM03 Excessive Agency, ASI03 Identity & Privilege Abuse | The agent uses a tool it should not have, or a credential it should not hold | One identity, three tools; the destructive tool is granted to no one; the records key lives only with the records service and the MCP server; the agent's token is for the MCP server's audience only | Static check `mcp`: no destructive tool is granted. Evals: records deleted, gated at zero; requests beyond the agent's rights it declined, measured |
| ASI03 Identity & Privilege Abuse | A workload calls the models as no one, or as the agent, to spend its quota | The gateway requires a service account token for its own audience, checked against the cluster's keys; the quota is keyed on the token's subject, never on a header ([ADR 11](decisions/0011-the-gateway-knows-who-is-calling.md)) | Gateway job: no token, and a token for the Kubernetes API, refused with 401; a workload that writes `x-client-id: support-agent` is still held to its own quota. Static check `gateway`: a quota keyed on anything but `jwt.sub` fails |
| LLM07 Misinformation | The agent invents data | Nothing structural | Evals, grounding category: answers without invented data, measured |
| LLM10 Improper Output Handling | The agent's output is executed somewhere | The agent's output goes to the evals' scorer and to tools by schema; nothing executes it | Not applicable here |

## Residual risks

- **The model is fooled, and oversteps.** In the first runs, Granite-4.0-1B acted on an instruction hidden in a report in half the injection attempts and declined none of the requests beyond its rights; Qwen3.5-2B ignored every hidden instruction and still tried to email outside when a user asked it to. The architecture is designed for both; a reader should know them.
- **Misdirected email inside the company.** The schema holds recipients to the company's domain, not to the right person. A model that is fooled emails a colleague nobody named. In the run v1.1.0 was cut from, the four models that never wrote an outside address sent 47 such emails between them; the two that tried outside, and were refused, sent none. 39 of the 47 were an outside address with its domain swapped for the company's: the grammar re-addressing an attempt to send outside (ADR 13). A recipient allowlist per task, or a person approving each send, would close it.
- **No transparency log.** Signatures are checked by key alone. A stolen key signs anything, and nothing public records it. Keyless signing with a TUF mirror inside the boundary is the step after kyverno#17883.
- **The keys are made per run.** In CI the operator's signing key and the boundary's CA are generated on the runner. In a real install they are the site's, kept off any build machine.
- **No runtime isolation for the agent here.** The agent's side runs under the restricted Pod Security profile, not under gVisor; the sandbox repository is where that is built.
- **One node, one registry, one replica of each service.** A reference for the controls, not for availability.
- **The price is a list price from a third-party snapshot.** `evals/pricing.json` says where it comes from.
