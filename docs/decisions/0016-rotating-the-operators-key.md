# 16. Rotating the operator's key with the model served

- Status: accepted
- Date: 2026-10-20

## Context

The operator's key decides which model may run (ADR 3): admission refuses a model whose signature and AI-BOM it cannot verify with that key. A key is rotated on a schedule, and at once when it may have been copied. With a policy that trusts one key, a rotation is a cliff. Switch the key in the policy and every model signed with the old one fails at its next restart: a node reboot takes the service down. Keep the old key to avoid that, and a stolen key keeps working. Until now the repository showed one key and no way from it to the next.

## Decision

- **Three phases, each a policy rendered from the one that runs.** Before: the operator's key. Overlap: the operator's key and the next one, either verifying. After: the next key alone. `tests/e2e/rotation.sh` renders each from `admission/verify-models.yaml` itself, adding the next key as a second attestor and changing which attestors the expressions name, so the drill rotates the policy that runs and not a copy. Kyverno 1.19.1 counts the attestors that verify an image (`verifyImageSignatures` in `pkg/cel/libs/imageverify/impl.go`), so "more than none" in the overlap means either key.
- **Re-sign during the overlap.** While both keys are trusted, the operator signs the served model and attests its AI-BOM with the next key. A model nobody re-signs keeps running, and stops at its next restart once the old key is retired; that is the point of retiring it.
- **A third key pair and two plants.** `scripts/model.sh sign` makes `next` beside `operator` and `stranger`; `scripts/model.sh plants` adds `plant-retired`, signed and attested with the operator's key alone, and `plant-next`, with the next key alone, each with an AI-BOM the site allows. They cross in the bundle like everything else.
- **Daily, with a model served.** The gateway job runs the drill last, on Granite-4.0-1B: before, `plant-next` is refused and `plant-retired` and the served model are admitted; in the overlap, `plant-next` is admitted and the others still are, and the served model is signed with the next key; after, `plant-retired` is refused, however recently Kyverno admitted it, `plant-next` and the served model are admitted, and the served model, restarted, comes back. Then the policy is put back as it was.
- **Each check flips.** `plant-next` must be refused and then admitted; `plant-retired` admitted and then refused. A check that could not fail would give the same answer in every phase, so the drill is its own control.

## Consequences

- During the overlap both keys are trusted. It lasts as long as re-signing takes, and the drill shows it is minutes for one model.
- The drill signs from the runner, which stands for the operator's machine, straight into the registry inside as the loader (ADR 2). At a site the operator signs outside and the signatures cross in the next bundle; the policy steps are the same.
- A key thought copied is retired the same way, faster: sign what runs with the next key, then trust only the next. Anything signed only with the old key, a model an attacker signed included, is refused from then on.
- Kyverno caches what it verified. The drill requires the retired key's model to be refused within a minute of the policy changing, so a cache that kept the old answer would fail it.

## Alternatives

- **Keyless signing with a transparency log.** The identity signs, not a long-lived key, and there is nothing to rotate. Inside the boundary it needs a TUF mirror and the log's keys carried in; ADR 3 keeps it for after kyverno#17883.
- **A key in a KMS or an HSM** (cosign takes a KMS URI). The private key never leaves it, which narrows the reasons to rotate, not the need; the policy steps are the same.
- **Switching keys in one step.** Every model signed with the old key fails at its next restart. A rotation that needs an outage is one nobody runs.
- **Never retiring the old key.** A stolen key keeps signing models the cluster runs.

## How to explain this to a customer

The key that decides which model may run can be changed without stopping the model. For a short overlap the cluster accepts both keys; the operator signs the running model again with the new key; then the old key is retired, and anything signed only with it, by the operator or by anyone who copied it, is refused from then on. The repository does this every day with a model running and proves that the model comes back after a restart.
