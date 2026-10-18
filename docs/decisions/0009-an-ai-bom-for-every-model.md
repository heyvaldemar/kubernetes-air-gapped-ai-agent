# 9. An AI-BOM for every model, read at admission

- Status: accepted
- Date: 2026-10-18

## Context

The signature says the operator approved these exact bytes. It says nothing about what the bytes are. A security or legal reviewer asks the next questions: which model is this, where did its file come from, at which revision, and under which licence may the site run it. Today the answers sit in `models/models.lock`, a file in a repository the cluster never reads. A model image signed by mistake, or one whose licence changed between releases, would be admitted on the signature alone.

## Decision

- **Every model image carries an AI-BOM**, a CycloneDX 1.6 ML-BOM written by `scripts/mlbom.py` from the model's line in `models/models.lock`: the model's name, the publisher's repository and revision, the file name, its sha256, its quantization and its licence. The same lock line always gives the same bytes: no timestamp, and a serial number derived from the file's hash. It validates against the CycloneDX 1.6 schema with `cyclonedx-cli`.
- **It is attested with the operator's key**, as an in-toto attestation of type `https://cyclonedx.org/bom`, with no transparency log, like the signature. It travels with the image in the bundle (ADR 8).
- **Admission reads it before the model may be mounted.** `admission/verify-models.yaml` requires the attestation to verify against the operator's key, and the BOM to declare a machine-learning model under a licence on the site's list, Apache-2.0 or MIT here. Each expression verifies before it reads, so a missing attestation is a refusal with its own message, not an evaluation error.
- **Each refusal has a planted pod.** A model signed by the operator with no AI-BOM, and one whose AI-BOM declares GPL-3.0-only, are refused with the reason; the release model with its AI-BOM is admitted. The static check `policies` fails if the policy stops reading the licence, and a planted violation shows it does.

## Consequences

- Changing what the site allows is one line in the policy, and the next model under another licence is refused until someone changes it on purpose.
- The AI-BOM is as trustworthy as the operator's key and the lock file it is written from: it records what the operator declares, it does not inspect the weights. The sha256 in it is the file the image was built from, and the image's digest is checked against the lock on every build.
- Admission reads one more attestation per model, from the registry inside.

## Alternatives

- **SPDX 3.0's AI profile.** Also fit for the job; CycloneDX is the format the sibling repository's admission already reads for container images, and one format across both keeps one way of reading them.
- **The licence as an image label.** Written by whoever builds the image and not signed separately; an attestation is signed by the key admission already trusts.
- **The model card itself.** Publishers' cards are prose with front matter in no fixed schema; the BOM takes the fields a policy can read and leaves the card where it is linked from.

## How to explain this to a customer

Every AI model we install comes with a signed bill of materials: what it is, where it came from, exactly which file, and the licence you are running it under. Your cluster reads that bill before it lets the model load, and it refuses a model whose licence is not on your list, the same way it refuses a model nobody signed.
