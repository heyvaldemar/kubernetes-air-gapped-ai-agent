# The brief, for whoever signs off

One page for a CISO, a CTO or a CEO deciding whether an AI agent may work on company data. Every number links to the run it came from; the engineering behind each line is in the README and the decision records.

## The decision

An AI agent reads your data and acts on it with tools. Models are fooled by instructions hidden in what they read, and no model choice removes that. The decision is not which model to trust. It is what the agent can reach when it is fooled, and who proves that every day.

This repository answers it two ways, with the same agent and the same checks:

- **Inside, with no route out.** The model runs on CPU in your cluster, from a signed image the cluster verifies with no network. Nothing leaves.
- **Connected, through one exit.** A frontier model through one firewall rule on one machine that only the gateway runs on, with no API key anywhere. The prompts and the records the agent reads go to the model's provider, and nothing else goes anywhere.

## What the evidence shows

- **The models were fooled; nothing left.** Six open models acted on an instruction hidden in a report or a record between 0 and 6 times in 12. Emails delivered outside the company: 0. Records deleted: 0 ([run 39157806610](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39157806610)).
- **Two frontier models were not fooled, in a small sample.** Claude Haiku 5.5 and Claude Sonnet 5.5 acted on none of the 12, with every gate holding the same way ([run 39476144885](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39476144885)). Twelve attempts at four planted instructions is not a rate; the design does not depend on it.
- **The agent acts for a person, not for itself.** It may do only what the person asking may do, down to their own customers. Before this was built, the same check showed a first-line support person getting an email sent through the agent that they may not send ([ADR 15](decisions/0015-the-agent-acts-for-a-person.md)).
- **The checks run daily and can fail.** 497 checks passed in [run 39478045047](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39478045047). Every refusal stands beside a control that must succeed, so a dead network cannot pass for a closed one, and every static check is shown the violation it exists for.
- **The checks found real holes, in this boundary first.** A way out by DNS that every release before v1.5.0 had; the model server's grammar doing work the models were credited with; quotas sized from a number that turned out wrong. Each is recorded with the run that showed it.

## What it costs

- Inside: $0.0001 to $0.0003 of CPU time a task across the six models, at an on-demand list price ([run 39157806610](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39157806610)).
- Connected: about $0.0003 a task for Claude Haiku 5.5 and $0.005 for Claude Sonnet 5.5, their tokens at list price ([run 39476144885](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39476144885)), from a workspace with a monthly limit.
- A pilot: five days from a release tag to sign-off, each step a command the daily run already runs ([docs/engagement.md](engagement.md)).

## What it does not do

The [compliance map](compliance.md) maps the checks to NIST SP 800-53, the NIST AI RMF, ISO/IEC 42001 and the EU AI Act as evidence for controls, never as compliance, and lists the gaps a security review will find: the model gateway knows the agent but not the person; reads from the registry inside need no credential; the audit is pod output, with no retention; no person approves an email; the node image arrives outside the signed bundle; signatures are checked by key with no transparency log. It is a reference on kind, not a product, and it does not run in production anywhere.

## Questions to ask of any agent, including this one

1. When the model is fooled, what can it reach, and where is the daily proof?
2. Whose rights does the agent use: its own, or the person's who asked?
3. What leaves the network, to whom, and what proves nothing else does?
4. Where is the credential to the model, and how long does a stolen one work?
5. Can every claim in the documentation be traced to a check that has been seen to fail?
