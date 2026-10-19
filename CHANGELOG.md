# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/releases/tag/v1.0.0
