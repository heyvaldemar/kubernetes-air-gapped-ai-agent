# 9. An AI-BOM for every model, read at admission

- Status: accepted
- Date: 2026-10-18

## Context

The signature says the operator approved these exact bytes. It says nothing about what the bytes are. A security or legal reviewer asks the next questions: which model is this, where did its file come from, at which revision, and under which licence may the site run it. Today the answers sit in `models/models.lock`, a file in a repository the cluster never reads. A model image signed by mistake, or one whose licence changed between releases, would be admitted on the signature alone.

## Decision

- **Every model image carries an AI-BOM**, a CycloneDX 1.6 ML-BOM written by `scripts/mlbom.py` from the model's line in `models/models.lock`: the model's name, the publisher's repository and revision, the file name, its sha256, its quantization and its licence. The same lock line always gives the same bytes: no timestamp, and a serial number derived from the file's hash. Every model's AI-BOM is validated against the CycloneDX 1.6 schema with `cyclonedx-cli`, pinned by digest, on every push (static check `mlbom`, with a planted violation that shows it can fail).
- **It is attested with the operator's key**, as an in-toto attestation of type `https://cyclonedx.org/bom`, with no transparency log, like the signature. It travels with the image in the bundle (ADR 8).
- **Admission reads it before the model may be mounted.** `admission/verify-models.yaml` requires the attestation to verify against the operator's key, and the BOM to declare a machine-learning model under a licence on the site's list, Apache-2.0 or MIT here. Each expression verifies before it reads, so a missing attestation is a refusal with its own message, not an evaluation error.
- **Every licence of every model, not any one.** *Amended 2026-10-21.* The rule admitted a BOM if any machine-learning component had any licence entry on the list. A BOM listing Apache-2.0 beside CC-BY-NC-4.0 passed, and so did one whose second model had no licence at all; an SPDX expression was refused only because evaluating it raised an error. A reader's reply to a post about this repository pointed at it: OR and AND carry different obligations. Now there must be at least one model in the BOM, every model must have at least one licence entry, and every entry must be an SPDX id on the list. CycloneDX does not say whether two entries mean both apply or either may be chosen; every entry allowed is the reading that is safe under both. A licence written as an SPDX expression is refused at admission on purpose, with its own message, and so is a component nested where the rule does not look: CEL has no SPDX parser, and a rule that looked for an allowed id inside an expression would admit `Apache-2.0 AND CC-BY-NC-4.0`.
- **An expression is evaluated where the BOM is made.** `scripts/mlbom.py` parses an SPDX expression from the lock line (WITH binds tighter than AND, AND than OR) and writes the first reading, in the order written, whose every licence is on the site's list, read from the policy so the list has one home: the ids marked `acknowledgement: concluded`, the expression kept beside them as the property `license-declared`. `Apache-2.0 OR CC-BY-NC-4.0` becomes Apache-2.0; `Apache-2.0 AND MIT` becomes both; `Apache-2.0 AND CC-BY-NC-4.0` has no reading on the list, and no BOM is written. A licence with an exception has no id to be written as, and is never concluded. CycloneDX 1.6 does not let an expression and ids share one list, which is why the declared expression is a property.
- **Each refusal has a planted pod.** A model signed by the operator with no AI-BOM; one whose AI-BOM declares GPL-3.0-only; one listing Apache-2.0 beside CC-BY-NC-4.0; one with a second model and no licence for it; one whose licence is the expression `Apache-2.0 AND MIT`. Each is refused with the reason. The release model with its AI-BOM is admitted, and so is one declared `Apache-2.0 OR CC-BY-NC-4.0` and concluded to Apache-2.0. The static check `policies` fails if the policy stops holding every entry of every model or reads past an expression, `mlbom` holds nine expressions to their conclusions, and four planted violations show they can fail.

## Consequences

- Changing what the site allows is one line in the policy, and the next model under another licence is refused until someone changes it on purpose.
- The AI-BOM is as trustworthy as the operator's key and the lock file it is written from: it records what the operator declares, it does not inspect the weights. A concluded licence is the operator's conclusion, made by a rule anyone can rerun on the lock line. The sha256 in it is the file the image was built from, and the image's digest is checked against the lock on every build.
- Admission reads one more attestation per model, from the registry inside.

## Alternatives

- **SPDX 3.0's AI profile.** Also fit for the job; CycloneDX is the format the sibling repository's admission already reads for container images, and one format across both keeps one way of reading them.
- **The licence as an image label.** Written by whoever builds the image and not signed separately; an attestation is signed by the key admission already trusts.
- **The model card itself.** Publishers' cards are prose with front matter in no fixed schema; the BOM takes the fields a policy can read and leaves the card where it is linked from.

## How to explain this to a customer

Every AI model we install comes with a signed bill of materials: what it is, where it came from, exactly which file, and the licence you are running it under. Your cluster reads that bill before it lets the model load, and it refuses a model whose licence is not on your list, the same way it refuses a model nobody signed. Every licence on the bill must be on your list, not just one of them. When a publisher offers a choice of licences, the bill records which one you are using and why, and keeps what the publisher declared.
