# 6. Tools through the sandbox's MCP server, with arguments held by schema

- Status: accepted
- Date: 2026-10-18

## Context

kubernetes-ai-agent-sandbox v1.1.0 built the door between agents and tools: an MCP server that knows who is calling, grants each identity its own tools and audits every call, in front of a service whose key the agent never holds. That repository proves it with a deterministic agent, on purpose. This one puts a real model behind the door.

A grant answers which tool an agent may call. It does not answer with which arguments. An agent granted `send_email` to write to colleagues can be talked into writing to anyone.

## Decision

- **The same server**, vendored from the sandbox (`manifests/mcp/`), the same TokenReview identity, the same rate limit, the same audit line per call. The agent's one credential is a ServiceAccount token for the server's audience, `mcp.boundary.heyvaldemar.com`.
- **One identity**, `support-agent`, granted `records_lookup`, `quarterly_report` and `send_email`. `delete_record` exists on the server and is granted to no one; a static check fails the build if it is.
- **Arguments held by the tool's schema.** `send_email`'s recipient must match `^[A-Za-z0-9._%+-]+@acme\.example$`. The server validates every call against the schema before any upstream sees it. With Granite the model never wrote an outside address in the first place; with Qwen it did, sixteen times in its first run, and the server refused every one: the check that matters is the server's.
- **The network allows the agent two destinations**, the MCP server and the model server, and the model server answers the agents and starts nothing of its own.
- **No gVisor here.** The agent's side runs under the restricted Pod Security profile; the sandbox repository is where runtime isolation is built and proven.

## Consequences

- Data leaves only through a tool, and the tool's schema decides where to. The evals check the outcome in the outbox, not in the model's answer.
- The schema is a domain, not a person: the model can still email the wrong colleague, and Granite did (ADR 5).
- Two copies of the server now exist. The sandbox is the source; changes go there first.

## Alternatives

- **A recipient allowlist per task**, or a human approving each send. Closes the misdirection; costs a workflow this reference does not model.
- **gVisor for the agent here as well.** Adds the node-level install to the boundary's seed; worth it when the agent runs code, which this one does not.

## How to explain this to a customer

The agent reaches your systems only through one door that checks who it is and what it asked for. It can be allowed to send email, and still only to your own company's addresses: the door checks every address before anything is sent. What it cannot be stopped from doing is sending the right report to the wrong colleague, and we measure and report that too.
