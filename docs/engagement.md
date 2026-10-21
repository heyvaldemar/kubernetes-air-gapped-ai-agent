# Putting this on a site with no route out

An air-gapped AI install rarely fails on the model. It fails on the first morning: a registry the site's CA does not sign, an image nobody brought in, a file nobody may carry across, and a security team seeing the controls for the first time on the day they are asked to approve them. This is the engagement as five days, each ending with something the customer can check for themselves.

It is a plan for a pilot, not a claim about anyone's production. Every step names the command or the file that does it, and each command is one this repository runs on every e2e run; static check `docs` fails if one is not, or if the tag below is not the latest release.

## Before the first day

| The customer decides or provides | Why it is asked before, not on the day |
|---|---|
| A Kubernetes cluster at 1.36 or later, or a host for kind for the pilot | image volumes, how the model is mounted, are GA from 1.36 |
| A registry inside, or a host where zot may run | everything the cluster runs is pulled from it |
| The CA the registry's certificate comes from: theirs, or one made for the boundary | admission fetches signatures over TLS and must trust it |
| Who holds the operator's signing key, and where | the key decides what may run; it never sits on a build machine |
| How one file crosses: a data diode, removable media, a transfer service | the whole install is one file, and its size is known in advance |
| Two vCPU, and 3 to 6 GB of memory, for the model server per replica | the model runs on CPU; 1B to 4B models were measured on that budget |
| What the tools reach: the records system, the mail domain | `send_email`'s schema holds recipients to one domain; it has to be theirs |
| Who signs off on day 4 | the security review is a meeting with a name on it |

## Day 1: the bundle, outside

Built from a release tag on a connected Linux machine with Docker, never from a branch:

```bash
git checkout v1.6.0
./scripts/airgap.sh registry && ./scripts/airgap.sh seed   # the staging registry
./scripts/model.sh build && ./scripts/model.sh sign         # the model, rebuilt and signed
./scripts/admission.sh fetch                                # the admission chart, checked
./scripts/gateway.sh fetch                                  # the gateway's CRDs and charts, checked
./scripts/bundle.sh create                                  # .cache/airgap/bundle.tar, signed
sha256sum .cache/airgap/bundle.tar
```

`MODEL=` picks the model from `models/models.lock`. The sha256 is read to the customer over a second channel, a phone call or a ticket, before the file moves. A file that arrives with a different hash is not loaded, whatever the signature says.

**Done when:** the customer holds `bundle.tar`, `bundle.tar.sigstore.json` and the operator's public key, and the hash they computed is the one they were told.

## Day 2: inside

```bash
./scripts/airgap.sh registry && ./scripts/airgap.sh mirror  # or their registry, and its mirror config
./scripts/bundle.sh load                                    # signature, then checksums, then the load
./scripts/admission.sh install && ./scripts/admission.sh policy
./scripts/serve.sh && ./scripts/tools.sh
./scripts/gateway.sh install                                # the one way to the models: who calls, how much
./tests/e2e/run.sh                                          # the acceptance test
```

`bundle.sh load` reads nothing from a file whose signature does not verify, and loads nothing from one whose checksums do not match. The acceptance test is the one CI runs every day: a pod and the node fail to reach the internet and to resolve a public name, the registry answers only over TLS, unsigned weights and weights signed by another key are refused, the signed model is admitted, and everything in the registry is what the file carried ([ADR 8](decisions/0008-one-signed-file-across-the-gap.md)). The gateway is the only way to the models: a caller without a token for its audience is refused, and each caller has a quota and a token budget ([ADR 10](decisions/0010-one-gateway-in-front-of-the-models.md) to [12](decisions/0012-a-token-budget-per-caller.md)).

**Done when:** `tests/e2e/run.sh` passes on their cluster, and its output is attached to the change record.

## Day 3: their model, their tasks

```bash
./scripts/evals.sh                                          # the agent through the tasks, through the gateway
```

The evals in `evals/tasks.json` are a starting set. The customer's own tasks go in the same format: a question, the tool calls it should make, what the answer must and must not say. Candidate models go into `models/models.lock`, one line each, pinned by revision and sha256, and the e2e matrix runs every candidate through the same boundary ([ADR 7](decisions/0007-every-model-through-the-same-boundary.md)).

The choice is made from the table the run writes, `leaderboard.md` on the `status` branch: how often each model was fooled, what it tried, what got out, what a task cost. The boundary's numbers have to be zero for every candidate. The model's numbers decide which candidate.

**Done when:** the customer has picked a model from the table, and the table is in the change record.

## Day 4: the security review

The meeting walks [the threat model](threat-model.md) line by line: each threat, its control, the check that shows the control works on every run, and what is not covered. Nothing is shown that the run did not produce. The evidence pack is the release (its archive, keyless signature and provenance), the run's JSON, and the decision records, each ending with how the choice is explained to someone who did not make it.

The residual risks are said out loud: the model is fooled, and can email the wrong colleague inside the domain; signatures are checked by key without a transparency log; one replica of everything.

**Done when:** the named person has signed off, or written down what has to change first.

## Day 5: handover

| The site will need to | How |
|---|---|
| update images or the model | a new bundle from a new release tag: day 1 and day 2 again |
| rotate the operator's key | sign the current model with the new key, update the policy's public key, then retire the old one |
| give the agent a new tool | a grant in `manifests/mcp/policy.json`, a schema for every argument, and an eval task that tries to misuse it |
| know it still holds | the e2e run, daily, on their side: the same checks, the same gates |

**Done when:** someone on the site has done each of the four once, with the engineer watching rather than typing.

## What this does not promise

Availability: one node, one registry, one replica of each service. GPU throughput: everything here is measured on CPU. A model that is not fooled: the architecture is built for one that is.
