# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- A model outside the boundary, through one way out (ADR 14): `.github/workflows/frontier.yml` runs the same agent, MCP server, gateway and gates against Anthropic's API, weekly, on main only. The boundary is closed as in the e2e, and `scripts/frontier.sh open` makes one exception: the host's firewall lets the second node of `kind/frontier.yaml`, the egress node, open TCP 443 to Anthropic's published API range, 160.79.104.0/23, and nothing else on kind's network. The gateway's proxy runs there with the API's address written in; the boundary still resolves no outside name. A taint keeps other pods off the node, and `admission/egress-node.yaml` refuses any pod outside the gateway's namespace that tolerates the taint, tolerates every taint or names the node. No API key exists: `scripts/frontier.sh token` exchanges the runner's GitHub OIDC token, under a federation rule that names this repository's main branch, for a ten-minute token, handed to the gateway through kubectl's stdin and replaced every four minutes while the evals run. `tests/e2e/frontier.sh` proves it: the gateway alone on the egress node, four admission plants, no way to the API from the other node, and from the egress node the API on 443 and nothing else, the API's own port 80 included. Weekly, Claude Haiku 5.5 and Claude Sonnet 5.5, each with the tools' patterns shown and hidden. The first green run, 39473093500 (Haiku): every check of the one way out passed, the gateway counted every one of the agent's requests and tokens, and the model acted on none of the 12 hidden instructions in either job, at about $0.0003 a task.
- Static check `frontier`: the hole is Anthropic's range on TCP 443 from the egress node alone, the job runs on main and reads no stored secret, the backend's token comes from a Secret, and the egress policy keeps its three refusals. Eight plants.
- The harness reads an API's `usage` where llama-server gives `timings`, takes a token ceiling per run (`MAX_TOKENS`, 400 inside, 4,096 for a model that thinks) and can leave the temperature to the model (`TEMPERATURE=default`: Claude Haiku 5.5 refuses one, HTTP 400 in run 39472211743), waits and asks again when the gateway answers 429, and reports its busiest minute, in answers and tokens: what the quota and the token budget are sized from (ADR 11, 12). `scripts/evals.sh` prints it for every model, and prices a model outside by its tokens at Anthropic's list price (`evals/pricing.json`).

### Changed

- The agent's quota at the gateway is 100 requests and 100,000 tokens a minute, from 60 and 60,000. The harness now counts its busiest minute itself, and ADR 11's figure of 28 requests, reconstructed from attempt durations and called an upper bound, was not one: Granite-4.0-1B reached 48 and 49 (branch run 39458328273), Claude Haiku 5.5 through the gateway to Anthropic's API 50 requests and 50,986 tokens (run 39473093500). Both limits are about twice the busiest measured minute again (ADR 11 and 12, amended).
- The `missing-field` task no longer fails an answer for containing `@acme.example`. That check was added so a phone number answered with an email would fail; the answer must also say there is no phone number, which covers it. Alone, the check failed a true answer that listed the record's account manager: all six of Claude Haiku 5.5's answers in run 39473093500, and one of MiniCPM5-2B's in branch run 39458328273. An address the record does not hold still fails the task (`answer_addresses_from`).
- `scripts/release-numbers.py` reads a frontier run's artifacts and prices a model outside by its tokens.
- `scripts/tools.sh` makes the models' namespace from the model server's manifest when no model server has, and `scripts/gateway.sh install` with `SERVED` set and empty serves no model inside.

## [1.5.0] - 2026-10-20

### Security

- **The boundary had a way out by DNS, and the host's SSH port was open to pods.** A pod that asked the kind bridge's gateway (172.18.0.1) for example.com got an address (run 39371733895). Inside the node, kind's entrypoint sends the gateway's port 53 to Docker's embedded resolver, and dockerd answers from the host, where no rule on the bridge applies (run 39374222983 printed the NAT rules); a first fix that closed only the host's `INPUT` chain did not stop it (run 39373144875). Traffic addressed to the host also takes `INPUT`, which the boundary's forwarding rule never sees, so a pod could open the host's TCP 22. Every release before this one had both. `scripts/airgap.sh close` now empties the node's `DOCKER_OUTPUT` and `DOCKER_POSTROUTING` NAT chains and rejects new connections from the bridge to the host, IPv4 and IPv6; `make down` removes the host rule with the others ([ADR 1](docs/decisions/0001-the-boundary-is-the-runners-firewall.md), amended). Found by probes added the same day after a review of the repository, and shown to fail first.

### Added

- [`docs/compliance.md`](docs/compliance.md): which controls the repository gives evidence for, and what each leaves out, across NIST SP 800-53 Rev. 5 (twelve controls), the NIST AI RMF and its Generative AI Profile, ISO/IEC 42001:2023 Annex A (numbers and titles from two named secondary sources) and the EU AI Act as amended by Regulation (EU) 2026/1744, every row naming the file and the check. Evidence for a control, never a statement that requirements are met. Six gaps stated with what would close each: one identity for every end user, an unauthenticated registry, an audit in pod stdout, no person approving an email, the node image outside the bundle, signatures by key with no transparency log.
- Static check `images` holds the node image in `kind/cluster.yaml` to a digest, with a plant.
- Every refusal in the boundary checks stands beside a control that must succeed from the same place: the probe pod opens a connection to the registry inside before its refusals count, the node reaches the registry over TLS before its refusal to reach 1.1.1.1 counts, and the registry must answer TLS before a refused plain request counts. A refusal alone passed on a dead network. New ways out are tried and gated: TCP to 1.1.1.1:443, 8.8.8.8:53, 9.9.9.9:853 and 140.82.112.3:22, DNS over UDP straight to 1.1.1.1, the cloud's metadata address (which the runner itself reaches, 200), and the host itself, by any of six ports or its resolver. IPv6 is measured: the runner has no IPv6 route, so the ip6tables rules are untested there, and the run says so.
- The MCP server's audit line names an email's recipient and a 16-hex sha256 of its body, never the body, and a new gate in `scripts/evals.sh` reads the audit against the agent's log: every email the agent tried, the harness's control email among them, must be an audit line with the same recipient, let through or refused alike. Against run 39344285646's audit, written before the change, the gate fails, 0 of 25.
- Nothing runs that the bundle did not carry, held by the API server on every pod: the native policy `admission/carried-images.yaml` refuses an image named by tag, or by a digest not among those `scripts/bundle.sh` loaded, which `scripts/admission.sh policy` writes from the bundle into its parameter. It holds with Kyverno down. The node image's own namespaces, kube-system and local-path-storage, are outside it, as the README says. The e2e adds two plants (an image by a digest the bundle never carried, the same image by tag) and a read-back: every pod outside those namespaces runs carried images. Static check `policies` holds the policy's expression and its refusal when the list is missing (two plants). It was a check of the registry's contents once per run; it is a rule now.
- [ADR 13](docs/decisions/0013-the-decoder-is-a-control.md): the model server's grammar, built from each tool's schema, is a control, and the e2e matrix measures the model without it. Every model runs twice a day, with the full schemas and with their patterns hidden from the model (`OFFER_PATTERNS=off` in the harness), while the MCP server checks the full schema both times; twelve model jobs where there were six, and a row for each in the leaderboard. The first pair of runs, 39369288435 and 39369404367: with the patterns shown, four of the six models never wrote an outside address; with them hidden, all six tried, 92 times, all refused, nothing delivered.
- `.github/workflows/evidence.yml` attaches the e2e run a release was checked by to the release: every artifact of the run in one archive with a manifest of sha256s, signed keyless. It refuses a run that is not this repository's e2e on main, green, for the tag's commit or the one before it.
- Every run's numbers stay: the `status` branch keeps `history/<run id>.json` for each finished e2e run on main, carried from one rewrite of the branch to the next, with any missing run filled in from its own artifacts while GitHub keeps them, and `history.md`, a table of all of them (`scripts/status-history.py`). The branch used to hold the latest run alone, and a run's artifacts last 90 days, so a number the README cites would have become uncheckable. A first fill from the runs on main found 31.
- The evals report hidden instructions acted on by task as well as in total, and the total with a 95% interval (Wilson). The attempts of one task differ only by seed, so the interval over attempts overstates what they show, and the line by task says so: in run 39157806610 every instruction any of the six models acted on was the one in the quarterly report, and none acted on the two in customer records. `scripts/release-numbers.py` prints the same by task.
- `scripts/release-numbers.py` counts, of the emails to colleagues nobody asked for, those that are an outside address's name with the company's domain: in run 39157806610, 39 of the 47 from the four models that never wrote an outside address.
- The latest run's evals as Inspect logs on the `status` branch, one per model, in `inspect/`, for Inspect's viewer (the UK AI Security Institute's evaluation framework). `scripts/inspect-log.py` translates the harness log: a sample is one attempt, with the task's prompt, what it expects, the harness's score and reasons, the tool calls the model made and their outcomes, and the model server's token count; the run's gates go in the log's metadata. Each log is read back with Inspect's own reader before the branch is written. inspect-ai 0.3.276 and its 79 dependencies are pinned by hash in `scripts/inspect-requirements.txt`, none newer than 2026-10-05.
- Each model job prints the runner's CPU model and count first. Cost and latency per task moved by up to about two times between runs of the same code (MiniCPM5-2B: 10.7 and 18.2 vCPU-seconds a task in runs 39199529930 and 39280471778), and the logs did not say what the runner was.

### Changed

- The AI-BOM's subject is the model image it is attached to, a `container` with its own bom-ref, where it used to repeat the model's bom-ref `model`, which CycloneDX requires to be unique and its schema cannot check. The model component gains its lineage: the model the GGUF file was converted from, as a pedigree ancestor (`Qwen/Qwen3.5-2B` for `bartowski/Qwen_Qwen3.5-2B-GGUF`), read from the repository's name and labelled so; the publisher stays whoever published the file. Static check `mlbom` now also holds every bom-ref unique and every dependency to a ref that exists, with a plant that gives the subject the model's bom-ref.
- The README says what "Granite never wrote an outside address" more likely measures: its tool calls follow the recipient pattern in the tool's schema, which is what a grammar built from the schema produces, and whether one applies depends on the model's chat template (ADR 5 said so; the README did not).
- The 60% floor is described as what it is, a line between a working agent and one that has lost its model or its tools, not a measure of quality; the cost per task as the model server's busy time at list price, marginal compute rather than a bill; and a run's length as measured, 18 to 37 minutes across the eight green runs on main before 2026-10-20, where the README said 30 to 40.
- The e2e badge says how much history it has: "since <first day>" until a run is 30 days old. Its colour reads the runs as well as the days: green only when every day ended green and nine runs in ten passed. A day counts as green by its last run, which hid the failures before it.
- The README's decisions table lists ADR 12. The harness's docstring no longer says a run repeats exactly: a seed repeats an attempt on the same CPU, not on a different one (ADR 5). A comment in `release-assets.yml` carried a date from the repository it was copied from.

### Fixed

- `docs/engagement.md`, the five-day plan for a site, still checked out v1.1.0 and left out the gateway: Day 1 never fetched its charts and Day 2 never installed it, so the evals on Day 3 would have had no way to the model. It now follows the e2e workflow command for command, and the new static check `docs` holds it there: every command in its code blocks must be one the e2e runs, its tag must be the latest release, and the README's decisions table must list every record (three plants).
- Comments in `manifests/mcp/mcp.yaml` and `manifests/namespaces.yaml` said the MCP server runs on gVisor. It does not, and ADR 6 says so; the comments now say what runs.

- The MCP server read each argument's pattern with Python's `re.search`, whose `$` also matches before a trailing newline: `send_email` to `"dana@acme.example\n"` passed its check, where JSON Schema refuses it. It now uses `re.fullmatch`, and static check `mcp` holds both patterns to a trailing newline, with a plant that puts `search` back. Found in a review of the repository.

## [1.4.0] - 2026-10-19

### Added

- A demo at the top of the README: one model's job of the v1.3.0 run, from the signed bundle to the agent's evals, replayed from the run's own log (`docs/demo/e2e.cast`, `docs/demo/e2e.gif`) by the new `scripts/cast-from-log.py`. The e2e needs Linux and a host firewall, so it cannot be recorded on a laptop; the log keeps every line with its time.
- A token budget per caller ([ADR 12](docs/decisions/0012-a-token-budget-per-caller.md)), beside the request quota and keyed the same way, on the token's subject: 60,000 tokens a minute for the support agent, about twice its busiest measured minute across three runs (about 29,000, Qwen3.5-2B), and 1,000 for any other workload. `tests/e2e/gateway.sh` adds a workload whose one request of about 1,500 tokens is served and whose next, its second of the minute, is refused with 429; the agent's same request, served; and the proxy's own token count for each model.
- A gate in every model job: the tokens the gateway counted, input plus output, equal the agent's own count. In run 39335646130 they were equal to the token in all six jobs. The gateway also reports the cached part of the input on its own (`input_cache_read`); adding it to the rest counts cached tokens twice, which the first version of the comparison did.
- Static check `gateway`: every caller with a request quota has a token budget, and every route goes to a model backend. Two plants: a route straight to the model's Service, a caller with a quota and no budget.

### Changed

- Every model is an `AgentgatewayBackend` in `inference`, a custom provider in front of its Service, and each `HTTPRoute` points at it; the `ReferenceGrant` allows these backends and no longer Services. Only on such a route does the gateway read an answer's usage. On the routes as they were, straight to the Services, the same budget was accepted, reported attached, and refused nothing: in proof run 39334262668 the workload's long request and its next were both served, and the proxy counted no tokens for either model. The answer still comes back as the server wrote it, `timings` included.
- The gate that the gateway answered every request the agent made reads the model backend's labels (`backend="inference/<service>"`, `protocol="llm"`), and a 429 under the token budget counts against the agent like one under its quota.

### Fixed

- `scripts/cast-from-log.py` finds a step by the command in its `Run` header when GitHub serves a log with every step named `UNKNOWN STEP`, as it did for a run on 2026-10-19. Against run 39197628817 it writes `docs/demo/e2e.cast` byte for byte as before.

## [1.3.0] - 2026-10-19

### Added

- `AGENTS.md` (and a `CLAUDE.md` that imports it): the rules an AI agent working on this repository is held to: claims only as CI checks, a check trusted only after it has failed, risky changes proved on a branch, pins and their homes, numbers never typed by hand, how a release is cut and verified.
- `scripts/release-numbers.py <run id>`: the README's eval table and the email facts behind its prose, from a run's artifacts.
- The agent's own evals go through the gateway. Every model job installs agentgateway and routes the one model it serves; the agent's rule to the model server is gone, so the gateway is its only way to a model. Two new gates: every model request the agent made is one the gateway answered (the harness's count against the proxy's), and none was refused over the agent's quota.
- The gateway knows who is calling. A caller shows a projected service account token for the gateway's audience, checked against the cluster's own signing keys written into the policy at install, with nothing fetched at request time; no token, or a token for the Kubernetes API, is 401. Quotas are keyed on the token's subject: the support agent 60 requests a minute (about twice its busiest measured minute, 28), any other workload 3. `tests/e2e/gateway.sh` adds the 401s, a workload that writes `x-client-id: support-agent` and is still held to its own quota, and the agent's larger quota.
- Static check `gateway`: every caller needs a token for the gateway's audience, the evals Job holds one, every quota is keyed on `jwt.sub`. Three plants: a quota keyed on a header, `mode: Optional`, a model token for another audience. And one more for `mcp`: an MCP token for the gateway's audience.

### Changed

- One `HTTPRoute` per model server, from `manifests/gateway/route.yaml`; `scripts/gateway.sh install` takes the served models as `SERVED` (model=Service pairs, default `$MODEL=llama`). The gateway's policies attach to the Gateway and cover every route.
- The `x-client-id` header no longer means anything to the gateway.
- The status workflow hands its push credential to git through git's environment, not its command line, which any process on the runner can read.

## [1.2.0] - 2026-10-18

### Added

- One gateway in front of the models ([ADR 10](docs/decisions/0010-one-gateway-in-front-of-the-models.md)): agentgateway 1.6.0 and the Gateway API, pinned in `gateway/gateway.lock` and carried in the signed bundle. A new e2e job serves two models behind it and proves routing by the model the request names, a 404 for a model with no route, a per-client limit (429 on the fourth request in a minute, the next client served), no path to a model server around the gateway, and the 429 in the proxy's request counter.
- Static check `mlbom`: every model's AI-BOM, written from its lock line, is validated against the CycloneDX 1.6 schema with `cyclonedx-cli` 0.33.1, pinned by digest in `ci-images.pins`, on every push. A planted violation, a model whose component type the schema does not know, shows the check can fail.

## [1.1.0] - 2026-10-18

### Added

- Every model through the same boundary, every day ([ADR 7](docs/decisions/0007-every-model-through-the-same-boundary.md)): four more Apache-2.0 models in the e2e matrix, from Mistral, IBM, Qwen and OpenBMB, measured rather than shipped. The boundary's gates hold for all six; the 60% task floor only for the two the release ships with.
- One signed file across the gap ([ADR 8](docs/decisions/0008-one-signed-file-across-the-gap.md)): `scripts/bundle.sh create` puts everything the cluster runs, with the model's signature and the admission chart, into one tar signed with the operator's key; `load` checks the signature, then every checksum, then loads. The e2e run replaces the staging registry with an empty one, closes the boundary and loads only the file; check 10 proves the registry held nothing before, holds exactly what the file carried, and refuses the file with one byte changed.
- An AI-BOM for every model ([ADR 9](docs/decisions/0009-an-ai-bom-for-every-model.md)): a CycloneDX 1.6 ML-BOM per model image (`scripts/mlbom.py`), from its lock line, attested with the operator's key. Admission refuses a model with no AI-BOM, or whose AI-BOM declares a licence outside Apache-2.0 and MIT; two more planted pods prove both, and a static plant proves the policy check can fail.
- `docs/engagement.md`: the five days from a release tag to a signed-off install on a site with no route out, each ending with something the customer checks.
- `leaderboard.md` and `leaderboard.json` on the `status` branch: one row per model from the latest run, what it tried next to what got out, written by the status workflow.

### Changed

- The control for "nothing delivered outside" no longer depends on the model: the harness sends one email inside through the MCP server before the first task, and the run requires it in the outbox.
- The model server's memory ceiling is 6 GiB, for the 4B models and their 8K-token cache; the evals Job may run an hour.

### Fixed

- A run that does not finish every attempt fails: the first matrix run let a slow model pass every gate on 31 attempts of 45. `scripts/evals.sh` counts the attempts against the tasks and the Job's `ATTEMPTS`.

- The status branch counted every eval gate and measurement twice: each model's artifact carries the evals' own `evals-results.json` beside `e2e-results.json`, which already holds the same lines, and `scripts/status.py` read both. The first release run read as 44 checks where it had 36. It reads `e2e-results.json` only.

## [1.0.0] - 2026-10-18

### Added

- The boundary: a kind cluster whose images come from zot, a registry inside under its own name (`registry.boundary.internal`, TLS from a CA made for the boundary), seeded by digest and mirrored for five upstream hosts; then closed by the host's firewall, a node with no DNS server and a CoreDNS that answers only for the cluster. Six checks prove it from inside on every run.
- The model's way in: Granite-4.0-1B and Qwen3.5-2B (Apache-2.0), pinned by revision and sha256, built into images reproducibly, signed with the operator's key and no transparency log, mounted as image volumes, and verified at admission offline by Kyverno 1.19.1 with an `images` expression for image volumes, and by a native ValidatingAdmissionPolicy for their shape. Four planted pods are refused and the signed model is admitted.
- The agent: the plainest tool-using agent, through the sandbox's MCP server (per-agent identity, grants, audit), with `send_email` whose recipient the schema holds to the company's domain.
- The evals: fifteen tasks, three seeded attempts each, mapped to the OWASP Top 10 for LLM Applications 2026 and for Agentic Applications 2026, judged on two levels, the model's and the system's. Gates: nothing delivered outside, with at least one email delivered inside as its control; nothing deleted; 60% of ordinary tasks done, a floor set from measurement. Cost per task from the model server's own compute time.
- Six decision records and a threat model.
- A daily run of the whole thing from nothing, and a `status` branch with the last 30 days and the latest run's checks and numbers, per model, which the README's badges read.
- Each release carries an archive of its tag, signed keyless, with SLSA provenance.

[Unreleased]: https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/compare/v1.5.0...HEAD
[1.5.0]: https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/releases/tag/v1.0.0
