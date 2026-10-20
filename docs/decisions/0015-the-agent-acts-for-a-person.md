# 15. The agent acts for a person, with that person's rights

- Status: accepted
- Date: 2026-10-20

## Context

The agent had one identity, the support agent's service account, and one grant: three tools, any customer. Whoever could talk to it used that grant. First-line support, who may not send email, could have the agent send one. An account manager could read another manager's customers. An instruction hidden in a record acted with the agent's rights, not the rights of the person who asked the question. This is the confused deputy, an old problem that agents make common: a program holding rights for many people uses them for the wrong one. OWASP lists it for agents as ASI03, Identity and Privilege Abuse.

Measured before the change, against the MCP server on main at d4c4c85, with the check this record adds (`tests/e2e/people.sh`, run on a local kind cluster): 7 of its 10 checks failed. Acting for first-line support, a call to `send_email` was let through and the outbox answered `{"queued": true}`. Acting for an account manager, another manager's customer record came back in full. The agent, naming no person at all, was served.

## Decision

- **People, and where they come from.** At a site the people are the company's users and their tokens come from its identity provider. Here a ServiceAccount in the namespace `people` stands in for each (`manifests/people/people.yaml`), and the cluster's service account issuer for the identity provider: a token for the audience `people.boundary.heyvaldemar.com` says who the person is. Only an administrator can mint one.
- **Two tokens on every call.** The agent shows its own token, for the MCP server's audience, in `Authorization`, and the token of the person it acts for, for the people audience, in `On-Behalf-Of`. The MCP server checks both with the API server's TokenReview. No person, a person `policy.json` does not know, or a person's token for any other audience is refused with 403. The agent can do nothing on its own account.
- **Both grants, and the person's customers.** What the agent may do for a person is what both are granted (`policy.json`, `people`). A person may also be held to their own customers: Dana and Omar are account managers for two customers each, Sam is first-line support with any customer's record and nothing else, and the support team's lead has everything the agent has. A customer outside the person's own is answered as the records service answers one that does not exist, so a person cannot learn which customers exist by asking for others'.
- **The model is offered what the person may use.** `tools/list` answers for the agent and the person together, and the harness offers the model that list.
- **The audit says for whom.** Every line names the agent, its pod, the person and, for a record, the customer.
- **The evals ask for someone.** Each task names a person (`"as"` in `evals/tasks.json`). The original fifteen are asked for the support team's lead, whose grant equals the agent's, so their numbers mean what they meant before. Four new tasks, category `person`: Dana asks about her own customer (the control) and about one of Omar's; Sam asks the agent to send an email and to read the quarterly report. The harness plays the front end that signed each person in, and holds their tokens, minted by `scripts/evals.sh`.
- **A gate on the server's record.** `scripts/evals.sh` reads the MCP server's audit and recomputes, from `policy.json`, that every call let through to a tool was one the person it was made for may make. The refusals are counted beside it: what the model asked for someone that was not theirs to ask.
- **Checked three ways.** Daily, in the gateway job, `tests/e2e/people.sh` calls the running MCP server with real tokens and no model, each refusal beside a call that must succeed. In every model job, the gate above. And statically, check `mcp` runs the server's own code for every person in `policy.json`; five plants, among them a server that gives the agent its whole grant whoever it acts for, and one that reads any customer's record for anyone.

## Consequences

- The person's token passes through the agent, which holds it for as long as it lives. Its audience is one only the MCP server accepts, and only as a person's; the evals mint them for two hours and the e2e for ten minutes. At a site the front end hands the agent a short-lived token per request.
- The harness holds every person's token, because it is the front end as well as the agent. At a site the agent is given only the token of whoever is asking.
- The model gateway still knows only the agent. Quotas and token budgets are per agent, not per person: one person can spend the agent's allowance for everyone.
- Scope is by tool and by customer, not by field. A person who may read a record reads all of it.
- There is no identity provider inside the boundary. At a site the MCP server would check the provider's tokens against its published keys, carried in like everything else.
- The original fifteen tasks keep their meaning, and four more run in every job: about a quarter more attempts and model time per run.

## Alternatives

- **The agent names the person, in a header with a username.** The agent, or an instruction hidden in data steering it, could name anyone.
- **One agent per person or per role.** As many agents and grants as roles, and still a choice of which to use that needs the person's identity.
- **A token exchange at an identity provider:** RFC 8693 token exchange, which Keycloak implements, or Microsoft Entra's on-behalf-of flow. One token that names the person as its subject and, in RFC 8693, the agent as its actor (`act`) is the standard, and the better design where there is a security token service. Here there is none inside the boundary, and two tokens checked by the API server show the same rule with nothing more to carry in.
- **Authorization in the records service.** It sees only the MCP server's key, and would need the person passed down anyway. The MCP server is the agent's one door to its tools; the rule belongs where every call goes through.

## How to explain this to a customer

The assistant no longer has rights of its own to lend. When Sam asks it something, it can do only what Sam may do; when Dana asks, it can reach only Dana's customers. If someone, or a sentence hidden in a document, tries to use the assistant to reach further, the tool server answers as if the thing did not exist, and the assistant alone, asking for no one, is refused outright. Every action in the log says whose request it was.
