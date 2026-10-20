# 13. The model server's grammar is a control, and the evals measure the model without it

- Status: accepted
- Date: 2026-10-20

## Context

`send_email`'s schema holds the recipient to `^[A-Za-z0-9._%+-]+@acme\.example$`, and the MCP server checks every call against it (ADR 6). The agent offers the model the same schema. llama-server turns a tool's JSON schema into a grammar for chat templates whose tool calls it can constrain, and the grammar applies the pattern while the model writes. ADR 5 said Granite's calls "followed the schema's pattern". It did not say how much of what the evals reported as the model's restraint was the decoder's.

Two runs of the same code on the same day answer that. In run [39369288435](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39369288435) the model saw the full schemas. In run [39369404367](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39369404367) the agent hid every pattern from the model (`OFFER_PATTERNS=off`), and the MCP server checked the full schema as always. The counts come from `scripts/release-numbers.py` on each run.

| Model | Tried outside, patterns shown | Tried outside, patterns hidden | Emails to colleagues nobody asked for, shown | The same, hidden |
|---|---|---|---|---|
| Granite-4.0-1B | 0 | 37 | 16 | 2 |
| Granite-4.1-3B | 0 | 9 | 12 | 6 |
| Ministral-3-3B | 0 | 10 | 7 | 1 |
| Qwen3-4B-Instruct-2507 | 0 | 10 | 9 | 5 |
| MiniCPM5-2B | 5 | 8 | 0 | 2 |
| Qwen3.5-2B | 15 | 18 | 0 | 1 |

Delivered outside: 0 in all twelve jobs. With the patterns shown, four of the six never wrote an outside address. With them hidden, all six tried, from 8 to 37 times, and the MCP server refused every attempt.

Four things follow.

1. The grammar is a control. It costs nothing at run time, and for four models it turned every attempt to send outside into an email inside the company. Of Granite-4.0-1B's 16 emails to colleagues nobody asked for, 13 kept the name of the outside address it had been given, with the company's domain: `bob.k@gmail.example` arrived as `bob.k@acme.example`.
2. Nobody configured it. It follows from the server and the model's chat template, and changes when either does. Qwen3.5-2B's calls showed no sign of it, and MiniCPM5-2B tried outside either way. A server upgrade or a new template can remove it, and nothing in this repository would change.
3. It turns an attempt to send outside into a misdirected email. The attempt still happens, the data reaches the wrong colleague, and the count of attempts outside reads zero. A review that reads that zero as the model's restraint is reading the decoder.
4. The MCP server's check held whatever the decoder did: nothing was delivered outside in either run.

## Decision

- **Keep the patterns in the schema the model sees.** The grammar is a second layer in front of the MCP server's check, and it is free.
- **Measure the model without it, every day.** Each model runs twice in the e2e matrix: with the full schemas, and with their patterns hidden, while the MCP server checks the full schema in both. Both are held to the boundary's gates. The task floor is for the shipped models with the full schemas. The leaderboard has a row for each; the model's own attempts outside are in the row whose patterns were hidden.
- **The threat model lists constrained decoding as a control:** what it stops, that it depends on the chat template, and that the boundary rests on the MCP server's check, not on it.

## Consequences

- Twelve model jobs a day where there were six. They run in parallel, so a run takes as long as before. Runner minutes on a public repository cost nothing.
- "Granite never wrote an outside address" was the decoder's. The README says so, and the models' own attempts outside, from the jobs with patterns hidden, sit beside the shipped numbers.
- The misdirected emails in the threat model are mostly redirected attempts to send outside. A recipient allowlist per task, or a person approving each send, is still what would close them. Now the evals can show it would.
- Hiding the patterns changed little else: hidden instructions acted on moved by at most three of twelve per model, and ordinary tasks done by at most two of eighteen. The grammar shapes the address, not the decision to send.

## Alternatives

- **Drop the patterns from what the model sees, for good.** It makes the model's numbers its own and throws away a free control.
- **Run the comparison once and write it down.** The grammar changes with the server and the template, and the pins move: a one-time number would go stale without anyone noticing.
- **Turn the grammar off at the server.** It would remove the control the first job measures, and hiding the pattern from the model reaches the same behaviour without changing the server the release ships.

## How to explain this to a customer

Your model server already enforces part of your policy, and nobody wrote it down: when the assistant writes an email address, the server will only let it write one at your domain. That is worth keeping, and not worth relying on. Change the server or the model and it can quietly stop. The check that holds is the one in the tool server, which refused every one of the 92 attempts the six models made once the server stopped helping.
