# 17. No model is mounted while Kyverno is away

- Status: accepted
- Date: 2026-10-21

## Context

Kyverno checks the model's signature and reads its AI-BOM (ADR 3, ADR 9). It does that in a webhook, the API server asking it about every pod that mounts a model, and the policy says `failurePolicy: Fail`: if the webhook cannot be reached, the pod is refused. That reads as fail closed. It is fail closed only while the webhook's configuration exists.

Kyverno removes its own webhook configurations when its admission controller stops and its Deployment is at zero replicas or being deleted (`pkg/webhooks/server.go`, `cleanup`, when `runtime.IsGoingDown()`, Kyverno 1.19.1). It does so to keep a cluster without Kyverno from refusing everything. From then on the API server asks nobody. The game day that takes Kyverno down with a model served (`tests/e2e/gameday.sh`) saw both outcomes. In run 39541542574 Kyverno had not yet seen its own Deployment at zero when it stopped, all seven configurations stayed, and every model was refused. In run 39543289132 five of seven went, and the API server admitted a model nobody signed and one under a licence the site does not allow. The first result was timing, not design.

The native policies that need nothing running hold the path, the digest and what the bundle carried. Both planted models are in the bundle, signed by nobody or under the wrong licence, so they pass all three: only Kyverno refuses them.

## Decision

- **The API server refuses every model while Kyverno's webhook for the models is missing.** `admission/kyverno-guard.yaml` is a ValidatingAdmissionPolicy whose parameter is Kyverno's resource webhook configuration, `kyverno-resource-validating-webhook-cfg`, with `parameterNotFoundAction: Deny`. A pod in a verified namespace that mounts an image is admitted only if that configuration exists and holds the webhook for `verify-models` with `failurePolicy: Fail`. Kyverno scaled down, uninstalled, its configuration deleted by anyone, or its webhook turned to Ignore: the pod is refused by the API server itself. Kyverno back, it writes the configuration again, and models are admitted again.
- **It goes on after Kyverno has registered the webhook.** `scripts/admission.sh policy` waits for the webhook to appear under its name and stops if it never does, rather than install a guard that would refuse every model for good.
- **The game day proves it daily.** With Kyverno at zero, it waits up to half a minute for the configurations to go, so the case the guard exists for is the one tested, and records which way it went. A model nobody signed, one under a licence not on the list, and the signed model are each refused; the model already served keeps answering; Kyverno back, the seconds until the signed model is admitted. First run with the guard, 39546414520: Kyverno's configurations went from seven to two, its webhook for the models with them, the API server's guard refused all three, and the signed model was admitted again 31 seconds after Kyverno was scaled back.
- **Static check `policies`** holds every admission policy to `failurePolicy: Fail` and the guard to its parameter and `Deny`, with a plant for each.

## Consequences

- With Kyverno away, no new model pod starts, the signed one included. That is an outage of model deployments, not of models already running, which keep serving. A real cluster runs Kyverno's admission controller three times over (`aws-eks-reference-platform`), so this is a scale-down or an uninstall, done by someone, not a crash.
- The guard names Kyverno's configuration and its webhook by the names Kyverno 1.19.1 gives them. A Kyverno upgrade that renames either makes the guard refuse every model, which is loud and safe: `scripts/admission.sh` stops at install, and the e2e fails before main.
- Uninstalling Kyverno now stops models from starting until the guard is removed too. That is the point.

## Alternatives

- **Keep Kyverno from deleting its webhooks.** Kyverno 1.19.1 has no setting for it: the cleanup runs whenever the admission controller decides it is going down. And it would still leave the hole open to anyone who deletes the configuration by hand.
- **More replicas and a disruption budget.** They keep Kyverno up through node loss and rollouts. They do nothing against a scale to zero or an uninstall, which is the case that opens the hole.
- **Verify the signature natively.** The API server's CEL cannot verify a signature or fetch an attestation. Native policy can hold the shape of the reference, which `model-volumes.yaml` does, and can refuse when the verifier is missing, which this does.

## How to explain this to a customer

The component that checks every AI model's signature can be stopped, and when it is, by design it steps out of the way. Left there, a model nobody signed would start. We add a rule that Kubernetes enforces on its own: while that checker is not in place, no new model starts at all. The models already running keep serving, and a daily drill stops the checker and shows both.
