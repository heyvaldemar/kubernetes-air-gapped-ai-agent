# 25. Each cloud run's results, signed by the repository that ran it, on a branch that does not expire

- Status: proposed, 2026-11-11, on branch `keep-cloud-results`. The workflow runs on main only, so it has not run yet; the script it calls has read three real runs and passes 30 cases against a GitHub made of files
- Date: 2026-11-11

## Context

Each run on AWS (ADR 18), GKE (ADR 22) and AKS (ADR 23) uploads what it checked as an artifact, `e2e-results-<cloud>`, and GitHub keeps it for 90 days. The README, the status branch and anything built from these runs point at them by run id.

Two things are wrong with an artifact as evidence.

It expires. The first scheduled AWS run that passed, [39744285464](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39744285464), loses its results on 2027-01-20. After that a reader can see that the run was green and nothing of what it checked.

And nobody outside can fetch it without an account. On 2026-11-11 GitHub's API answered an anonymous request for a run's record, for the list of a workflow's runs and for an artifact's record with its sha256 with 200, and the artifact's bytes with 401. So a copy of the results that someone else holds rests on their word that it is the file the run uploaded, checkable against GitHub's digest only while the artifact lives, and only by reading it through an account.

The release evidence (`evidence.yml`) already solves this for one run per release. The cloud runs are scheduled weekly, and most of them belong to no release.

## Decision

A workflow, `.github/workflows/cloud-results.yml`, keeps every finished cloud run's own record and results on a branch, `cloud-results`, signed by this repository.

1. **When.** After every run of the three cloud workflows on main, by `workflow_run`, whatever the run's conclusion; and by hand, for one finished run that already happened, by its id. It starts no cloud run.
2. **Which runs.** This repository's, from its own code and not a fork's, of `aws.yml`, `gke.yml` or `aks.yml`, on main, started by the schedule or by hand, finished. The workflow's `if:` holds a `workflow_run` to that, and `scripts/cloud-results.py` decides again from GitHub's own record of the run, so a run id typed by hand is held to the same.
3. **A failed run is kept too**, with whatever it uploaded, and a run that uploaded nothing leaves a record that says so. A week that went wrong has to be on the record, or it cannot be told from a week that never ran.
4. **The file is checked, then signed.** The artifact is downloaded with the workflow's own token and kept only when its sha256 is the digest GitHub reports for it and it is no larger than 5 MB. It is data: nothing in it is run and it is never unpacked to disk. The record, `record.json`, holds the run's facts (workflow, event, branch, commit, conclusion, times, jobs) and the file's sha256, and cosign signs the record keyless. One signature covers the run's facts and its file together, and its identity is exact: this workflow, at `refs/heads/main`.
5. **What is kept is kept for good, so it is searched first.** The file is read in memory for anything shaped like a credential: a JSON Web Token, a GitHub token, an AWS access key id or session token, a private key, a Google access token, a signed address, a bearer token, an Anthropic API key, a Hugging Face token, a kubeconfig's client key or token, a login and password in an address. An artifact that holds one is not kept, and the message names the kind and the file inside, never the value. A search of text sees nothing inside a compressed or binary file, so an archive is kept only when every file in it is `.json` or `.jsonl` and decodes as UTF-8, which is what every cloud run has uploaded so far.
6. **Least privilege, job by job.** The signing job may read runs and ask for an OIDC token; it cannot write. The job that writes the branch may write contents; it cannot sign. Neither runs in an environment, reads a stored secret or logs in to a cloud.
7. **The branch only grows.** It has no parent in main and holds results only: `<cloud>/<run id>-<attempt>/` with the record, its Sigstore bundle and the artifact, an `index.json` and a table. A record already there is never replaced. Runs of the workflow go one at a time, and a push that finds the branch moved reads it again and adds to that.

Anyone can then check a run's results with no account and nothing of this repository trusted:

```bash
cosign verify-blob record.json --bundle record.json.sigstore.json \
  --certificate-identity https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/.github/workflows/cloud-results.yml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
sha256sum e2e-results-aws.zip   # the value record.json gives as artifact.sha256
```

## What was measured, 2026-11-11

- Size. The 30 artifacts GitHub still holds are 241,237 bytes together: 17 of AWS, 7 of GKE, 6 of AKS. The largest is 17,517 bytes, the hand-run [42656218231](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/42656218231) with the GPU; an AKS run's is 732. A year of three scheduled runs a week is under 2 MB at that size.
- The script, read-only, against two real runs: the scheduled AKS run [42809539539](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/42809539539) (passed; 732 bytes, sha256 `95f61d15...4826`, GitHub's digest) and the scheduled AWS run [42005832115](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/42005832115) (failed; 13,527 bytes, sha256 `2a392572...13df`). Both records were written, the failed one as a failure.
- All 30 artifacts GitHub held were read, each with the digest GitHub reports, and searched for those twelve shapes of credential: none holds one, and every file in them is `.json` or `.jsonl` in UTF-8. They hold seven kinds of file: `e2e-results.json` in all 30, the evals' results, the agent's log and the MCP audit in 19, and the capacity measurements.
- `tests/static/cloud-results.py`, 30 cases against a GitHub made of files: a run on a branch, a fork's, another repository's, another workflow's, one a pull request started and one still going are not kept; nor is a file that is not the one GitHub reports, one larger than 5 MB, one of two artifacts of the same name, one that holds something shaped like a credential (each shape is tried), one that holds a file that is not `.json` or `.jsonl` or is not text, one that is no archive, or one that unpacks to more than 50 MB; nor a run whose id is written in another script's digits; a failed run, a run that uploaded nothing and an expired artifact each leave the record they should; a record the branch holds is not replaced.
- Static check `results` holds the workflow to the points above, and 34 plants in `tests/static/plants.tsv` break it and the script one way each. All 34 are caught.

The signature and the branch are not measured: the workflow can only run on main.

## Consequences

- A cloud run's results outlive GitHub's 90 days, and a reader needs no account and no trust in a copy: the signature is the repository's that ran the cloud.
- It keeps the runs that are still there. The results of runs whose artifacts had already expired are gone, and no record is invented for them.
- A cloud workflow renamed stops being followed. Static check `results` compares the names, and a plant renames one.
- The record is signed after the run, by another workflow, from GitHub's record of it. A cloud job signing its own results would tie the file to the job that made it. That is a change to three workflows that create billed resources, and it is not made here.
- The branch holds what the runs uploaded, the MCP audit and the agent's log among them, as the artifacts do today: synthetic records at acme.example. Unlike an artifact, a commit does not expire, which is why the file is searched before it is kept. The search knows twelve shapes; a secret of another shape would pass it.

## Alternatives

- **Each cloud job signs its own results.** The strongest chain, and no second workflow. It adds a signing step to jobs that hold a cloud credential, and a fault in it would turn a cloud run red after the money is spent.
- **`evidence.yml` for every cloud run.** It attaches to a release, and most cloud runs belong to none.
- **Leave it to whoever reads the artifacts.** Then every reader keeps a copy, each on its own word, and after 90 days none of them can be checked.
- **Keep the results on the `status` branch.** That branch is one commit, replaced each time, and written from the latest run: a record there can be replaced, which is what this must not allow.

## How to explain this to a customer

Every week a scheduled run builds the reference on each of three clouds, tries it from inside and destroys it, and each run writes down what it checked. Which weeks passed is what the branch's index shows. GitHub deletes that file after 90 days. From now on the repository signs each run's file and keeps it, failed runs too, so you can check any week's results yourself, with free tools and no account, long after GitHub has dropped the original.
