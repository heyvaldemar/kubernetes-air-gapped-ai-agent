# Working on this repository as an agent

Most of the code here is written by an AI agent, and the decisions and the verification are the maintainer's. This file is what the agent is held to. A reviewer can hold it to the same rules.

## What this repository claims

Every sentence in the README that says something holds is a check that runs in CI: `tests/e2e/run.sh`, `scripts/evals.sh`, `tests/e2e/gateway.sh` or `scripts/validate.sh`. A claim with no check is not written. It is a reference architecture, and nothing says otherwise: no wording about running anywhere in production or holding a certification (the fleet's conformance check refuses it in the README and the decision records).

## Before changing anything

- Read the decision record that covers it, under `docs/decisions/`. A change that alters a decision amends that record or adds one, in the same format, ending with how the choice is explained to a customer.
- `make check` runs the static checks and shows each one its planted violation (`tests/static/plants.tsv`). It must stay all caught, none missed, none stale.

## A check is trusted only after it has failed

A new or changed check ships with the violation it exists for: a planted manifest under `tests/e2e/plants/`, a row in `tests/static/plants.tsv`, or a deliberate sabotage run whose failing output is recorded in the commit message. A check that has never been seen to fail proves nothing.

## Proving a risky change

Run the full e2e on a branch before it reaches main:

```bash
gh workflow run e2e.yml --ref <branch>
```

The status page reads main only, so branch runs never touch the published numbers. GitHub serves a job's log only once the whole run has finished: to read one finished job early, cancel the rest.

## Pins

Everything is pinned and every pin has one home: images by digest in `airgap/images.txt` (the bundle is made from it), models by revision, sha256 and image digest in `models/models.lock`, the gateway in `gateway/gateway.lock`, CI images in `ci-images.pins`, tools in `tools.lock`, the admission chart in `admission/charts.lock`. A new model is `unpinned` until its first build prints a digest, and is pinned once two runners agree on it.

## Numbers

No number in the README or a release is typed by hand. `scripts/release-numbers.py <run id>` prints the table and the facts behind the prose from a run's artifacts, and the README names that run. When results differ between runs, find what changed (the runner, the harness, the model) before calling it noise. Gates are set from measurement and the record says why (ADR 5 is the example); a gate is never loosened to get a green run without that.

## Releases

- Fill `CHANGELOG.md` `[Unreleased]` in the same commit as the change.
- Tag only a commit whose e2e is green, or a docs-only commit right after one, and say which in the release notes: what is new, what was found while building it, how it was checked.
- After publishing, verify the signed archive the way a stranger would: `cosign verify-blob` with the release's `.sigstore.json`.

## Writing

Plain and specific. No em dashes, no marketing words, no claim the evidence does not carry. Name runs, commits and files. Commits are authored `Vladimir Mikhalev <10498744+heyvaldemar@users.noreply.github.com>` and carry no AI attribution lines.

## Never

- Print a secret, or put one in a file, a log or an argument. Keys and the boundary's CA are made per run.
- Turn off or weaken a check, a policy or a gate to get a run green.
- Touch anything outside this repository's own CI to test a change: no cloud resources, no outside services. The model runs inside the boundary.
