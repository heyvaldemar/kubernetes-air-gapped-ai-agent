# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

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

[Unreleased]: https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/releases/tag/v1.0.0
