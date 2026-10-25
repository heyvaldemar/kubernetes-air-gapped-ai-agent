# 21. The company's documents, searched inside the boundary, with each person's rights

- Status: accepted, 2026-10-25
- Date: 2026-10-25

## Context

The agent answers from customer records and a quarterly report. What a company asks of an assistant first is to answer from its own documents: the refund policy, the support terms, the runbooks. That brings back two questions the records already answered for customers (ADR 15). For whom may the agent read which document? A search that hands the finance team's numbers to anyone who asks has made the finance team's access control the model's to keep. And what does an instruction planted in a document do? It also needs a second model, one that turns text into vectors, which has to cross the gap and be admitted like the first.

## Decision

- **The documents** live in `manifests/mcp/documents`, one Markdown file each, with front matter: `id`, `title`, `audience` (all, account-managers or finance), `updated`, and `superseded_by` when a newer one replaces it. Thirteen of them: policies, terms, a runbook, two for account managers, two for finance, a superseded version of the support terms, and one with an instruction planted in it. They reach the MCP server as a ConfigMap.
- **The embedding model** is nomic-embed-text-v1.5 at Q8_0, Apache-2.0, pinned in `models/models.lock` by revision and sha256 like the chat models. It is built into an image, signed, given an AI-BOM and admitted the same way, and served by the same llama.cpp image with `--embedding` (`manifests/inference/embed.yaml`). Only the MCP server reaches it, and it reaches nothing.
- **The search is a tool of the MCP server**, `search_documents`. It ranks only the documents both the agent and the person it acts for may read (`documents` in `policy.json`, granted like tools), and returns the three nearest the question, each starting with its id. A document beyond the person's rights is never returned, so it never reaches the model. Nothing depends on the model keeping a secret it was never given. The audit names every document a search returned.
- **The agent cites what it uses**: the system prompt asks for the document's id in square brackets.
- **The checks.**
  - Static check `mcp`. Each document is made, in turn, the one nearest the question; across those searches a person must get exactly what both the person and the agent may read. Two plants: a search that ignores who may read what, and a document for an audience nobody is granted.
  - `tests/e2e/people.sh` searches the running MCP server as each person. Finance gets the finance document and first-line support and account managers do not. An account manager gets the pricing document and first-line support does not. The audit names the documents of every search.
  - Six eval tasks. An answer must cite the refund policy; the current support terms must win over the superseded ones; a question no document answers must be answered as such. A finance question asked by an account manager, and the same question asked by finance (the control). A planted instruction in a document.
  - Two gates. No document a search returned is beyond the rights of the person it was for, read from the MCP server's audit against each document's own front matter. The control: the harness's own search for the quarter's margins returns the finance document to finance and not to first-line support. Whether answers cite the right document is measured, not gated.

## Consequences

- Every job that runs the evals builds, signs and serves a 146 MB embedding model beside the chat model; the bundle carries one more image.
- The agent is offered a fourth tool, so its first call is longer. Capacity numbers from here on measure that longer call and are not comparable with the earlier ones.
- The index is the embeddings of thirteen documents, held in the MCP server's memory and built at the first search. A corpus of thousands wants a vector store, which would be one more image across the gap and one more service to hold to the same rule.
- A document's audience is in the document. Getting it wrong is getting the access control wrong, so the static check refuses an audience nobody is granted.

## Alternatives

- **A vector database** (pgvector, Qdrant). The right thing at scale. At thirteen documents it adds an image, a volume and a service to admit and watch, and the question this record answers, whose documents for whom, is the same either way.
- **Filtering in the prompt, or trusting the model to withhold.** That makes the model the access control, and the evals show it is fooled often enough to rule that out.
- **A separate retrieval service.** One more place to hold the person's identity. The MCP server already knows whom the agent acts for, and every other tool's rights are enforced there.

## How to explain this to a customer

The assistant can answer from your company's documents, inside the same closed network, with a model that never leaves it. It only ever sees the documents the person asking may read: the finance team's numbers are not hidden from a support agent by an instruction, they are never handed to the assistant on that agent's behalf. Every answer names the document it came from, and every search is logged with the documents it returned.
