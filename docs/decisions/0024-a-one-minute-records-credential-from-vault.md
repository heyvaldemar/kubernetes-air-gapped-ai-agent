# 24. A one-minute records credential from Vault, in place of the records key

- Status: accepted on kind, 2026-11-04 (branch `spike/vault-community`, run 41889356475); the cloud legs wait for the maintainer, so it is not on main yet
- Date: 2026-11-04

## Context

The records service (`manifests/records/records_api.py`) stands for another team's service. Until now it took one credential: a key that `scripts/tools.sh` made at install with `secrets.token_urlsafe(32)` and wrote as the same Secret, `records-api-key`, into two namespaces, `corp` for the service and `mcp` for the MCP server. The key had no expiry. It lived as long as the cluster. Anyone who read it once was the MCP server to the records service from then on. The service could not tell who called, only that the caller had the key. Taking it back meant a new Secret in both namespaces and a restart of both services, by hand, and nothing in the repository did it.

A skeptic asks why that needs one more component inside an air-gapped boundary. Kubernetes already issues short-lived tokens bound to an audience. The MCP server already checks agents' tokens with TokenReview (ADR 6), and the gateway already checks them offline against the cluster's keys (ADR 11). The records service could check a projected token of the MCP server's, for the audience `records-api`, the same way, with nothing new to carry, admit, unseal or license.

That is the honest runner-up, and what it would give is checked in this cluster, not assumed (`tests/e2e/vault.sh`, the first checks):

- **Ten minutes at least.** The API server refuses a token shorter than ten minutes (`kubectl create token --duration 1m`). A copied token checked offline works until it expires.
- **No one-token revocation.** Kubernetes cannot take back one token. Checked offline, it is good until it expires. Checked by TokenReview, until its pod or its service account is deleted. Deleting the pod brings a new one with a new token. Deleting the service account also stops the MCP server's TokenReview of every agent, so that is turning off the MCP server, not one credential.
- **Any workload, any audience.** A pod gets a token for any audience it names, for its own service account, with no permission to ask for. The audience says what a token is for, not who may hold one. The records service would have to know which subject to accept, so that rule would live in another team's code.
- **One signing key.** The cluster's service account key signs every token in the cluster. On kind it lives as long as the cluster.

The question is whether Vault adds something measurable on top of that, at a price worth paying. If not, the record says so and nothing is built.

## Decision

Vault Community 2.2.1 issues the records credential. The design is shape (a) of the spike's brief: a Vault identity token, a JWT that Vault signs, checked offline by the records service.

- **What the MCP server holds.** A projected service account token for Vault's audience, `vault.boundary.heyvaldemar.com`, rotated by the kubelet. The API server would refuse it, and so would the MCP server and the gateway. With it the MCP server logs in to Vault's Kubernetes auth, role `mcp-server`, and gets a Vault token that lives 60 seconds and can be used once. It uses that once, to read `identity/oidc/token/records-api`, the one path its policy, `records-caller`, allows. What comes back is the records credential: an RS256 JWT, audience `records-api`, scope `records:read outbox:send`, issued by `https://vault.vault.svc.cluster.local:8200/v1/identity/oidc`, valid 60 seconds. The MCP server keeps it until 15 seconds before it expires and then asks again.
- **What the records service checks**, itself, with the standard library: the signature, RS256 only, by a key in Vault's published key set; the issuer; the audience; the expiry; an issue time not in the future; a lifetime of no more than 60 seconds, so a credential minted with a longer TTL is refused even if Vault was set wrong; and a scope that covers the request. `GET /records` and `GET /records/<id>` need `records:read`, and `POST /outbox` needs `outbox:send`. `DELETE` needs `records:delete`, which no role in Vault issues, so the records service refuses a delete from anyone, the MCP server included, even if its grant were opened by mistake. Anything else is 401, or 403 for a valid credential without the scope. It logs the subject and the service account of every call.
- **Who may get one.** The Kubernetes role is bound to one service account, `mcp/mcp-server`, and to Vault's audience. Any other workload's login is refused at the issuer, the agent's own service account included. The rule lives in one place, Vault, and not in the records service.
- **The network.** Only the MCP server reaches Vault, on 8200. Vault reaches only the API server, for TokenReview, by the address `scripts/tools.sh` writes into its policy as it does the MCP server's. The records service never calls Vault. `scripts/vault.sh keys` writes Vault's public key set into the records service's ConfigMap, the way `scripts/gateway.sh install` writes the cluster's keys into the gateway's policy (ADR 11).
- **Not dev mode.** Integrated storage (Raft) on a persistent volume, one replica, TLS with a certificate from a CA made for this run, beside the registry's, and trusted by the MCP server alone. An audit device writes every request to Vault's log, with tokens hashed.
- **Unseal by Shamir, by the installer.** `scripts/vault.sh install` initialises Vault with five shares and a threshold of three, and unseals it with three. It writes the shares to `.cache/airgap/vault/` on the runner, mode 600, never printed, where the run's other keys are made (ADR 16: the runner stands for the operator's machine). It configures Vault with the root token, makes an operator token for the drills (a narrow policy, four hours), and revokes the root token. At a site the shares go to five people, and three of them unseal Vault after any restart. Auto-unseal was not chosen. It needs a cloud KMS, which is a way out of the boundary (ADR 1, 18, 22, 23); an HSM over PKCS#11, which Vault Enterprise has and Community does not; or Transit on a second Vault, which moves the same unseal to another server.
- **The static key path is gone.** No Secret, no mount and no key file anywhere, and the run's checker reads what the records service did from its own log, not with a credential (`scripts/evals.sh`).
- **The checks.** Static check `vault`, each shown its plant (`tests/static/plants.tsv`): no records key in any manifest or script; Vault's TTLs at or under the records service's limit, and that limit 60 seconds; the Kubernetes role bound to the MCP server's service account and namespace alone, and to Vault's audience; Vault's ingress from the MCP server alone; not dev mode; and the records service's check, run here against tokens signed by a key made for the check, refusing an expired token, a wrong audience, a wrong issuer, a lifetime over the limit, an unknown key, `alg: none`, HS256, a changed payload and a missing scope, and taking the valid one (the control). Static check `boundary` holds the Vault image to `airgap/images.txt`. On the running cluster, `tests/e2e/vault.sh`, in the gateway job: the Kubernetes facts above; the records tool through Vault's credential (the control); Vault refusing a login by the agent's service account, by another service account in the MCP server's namespace, and by the MCP server's own Kubernetes API token; an agent pod unable to connect to Vault; the records service refusing an expired credential, a credential for another audience signed by the same key, the cluster's own token for `records-api`, a credential minted while Vault's TTL was raised to an hour, no credential, and a random key, and refusing a delete with a valid one; a pod with a Vault image the bundle did not carry, refused at admission; the audit; and the revocation drill below.
- **Revocation, measured.** The drill disables the MCP server's identity in Vault, the way an operator cuts off a caller thought compromised. It measures three times over several rounds. First, how long until Vault refuses a new credential. Second, how long a credential copied just before still works at the records service, that is, until its first 401. Third, how long until the MCP server's records tool stops. Meanwhile the MCP server keeps answering its other tools. Then it enables the identity again and measures how long the records tool takes to come back.
- **Measured besides:** the credential's lifetime before (no expiry) and after; how long `scripts/vault.sh install` adds to the install; the Vault pod's memory and the image's size. The numbers come from a CI run on fresh runners, below.

## On kind, 2026-11-04

Branch run [41889356475](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/41889356475), every job on a fresh GitHub-hosted runner: all fourteen passed. The twelve model jobs ran the evals with the records tool on Vault's credential, every gate held, and the node-loss drill passed with Vault installed. `tests/e2e/vault.sh`, in the gateway job: 35 of 35 checks. Every number below is from that run (`scripts/release-numbers.py 41889356475 vault`, and the step times from the run's jobs).

| | Before (main, run 41829113374) | After (run 41889356475) |
|---|---|---|
| Life of the records credential | no expiry: the key lived as long as the cluster | 60 s, issue to expiry |
| Kubernetes' shortest token, for comparison | 600 s; any service account, the agent's included, was issued one for `records-api` | the same; the records service refuses it |
| Vault refuses a new credential after the cut-off | no issuer to cut off | 0.1 s in each of 3 rounds |
| A credential copied just before the cut-off, until its first 401 | never: a copy of the key works until someone rotates it by hand | 59.6 to 60.1 s, median 60.1 s, 3 rounds |
| The MCP server's records tool stops | only when both Secrets are replaced and both pods restarted | 38.4 to 44.5 s, median 39.4 s, 3 rounds, while its report tool answered |
| The records tool back after the identity is enabled | | 0.0 to 0.1 s |
| The tool side's install step, median of 14 jobs | 15 s (14 to 18) | 44 s (35 to 46); `scripts/vault.sh install` itself 16.5 s in the gateway job |
| The signed bundle | 25 image tags, 3.6 GB | 26, 4.2 GB: Vault's image for 386, amd64 and arm64, as HashiCorp's index carries it |
| Vault's pod after the drills | | 41 MiB of memory, 2.5 CPU seconds since it started; 468 KiB on its 1 GiB volume; 202 MB of image on the node |

Found while building it:

- **zot refused the image.** HashiCorp publishes Vault as a Docker manifest list, and zot took OCI media types alone: "manifest invalid" at the seed, in every job of branch run 41886694445. zot now takes Docker's manifests too (`compat: [docker2s2]`, ADR 2 amended), and stores the image by HashiCorp's own digest.
- **A plant that could not be caught.** Removing the records service's `alg` check did not fail static check `vault`: the signature is checked as RS256 over the signed header whatever it says, so `alg: none` and HS256 fail there anyway. The plant was dropped and the check kept, to name the reason in the log.
- **Vault's memory limit.** On a local kind cluster Vault's pod reached 187 MiB after two runs of the drills, against a limit of 256 MiB. A Vault killed for memory comes back sealed, so the limit is 512 MiB, with `GOMEMLIMIT` at 384 MiB. On the runner it used 41 MiB.
- **The checker read a stopping pod.** Right after the records service restarts, `kubectl logs deploy/records-api` can pick the old pod, still stopping. `scripts/evals.sh` and the drill read the newest pod's log.

## Consequences

- **What Vault adds that the projected token does not, each measured or shown by a check:**
  - A lifetime of 60 seconds where Kubernetes will not go under ten minutes.
  - Vault refuses a new credential at once, and the MCP server's other tools go on. A copied credential still works until it expires, at most 60 seconds, because the records service checks it offline. Vault does not make revocation instant: it makes the longest a copy works one minute, and it stops a caller without stopping the caller's workload.
  - Who may get a credential for the records service is decided by the issuer, for one service account. The records service only checks the signature, the claims and the scope.
  - The credential carries its scope, so the records service can refuse a delete that the MCP server's own grant would have stopped first.
  - Vault's audit names every credential it issued and every login it refused.
- **What it does not add here.** Per-caller identity is the same as with the projected token: one service account either way. Key rotation is a property of Vault this spike does not measure. Vault rotates its signing key every 24 hours and publishes the next key ahead of time, so a key-set snapshot holds through one rotation.
- **What it costs.** One more image across the gap, 0.6 GB of the bundle, under a licence that is not the repository's (below). One StatefulSet and one volume. About 29 s more for the tool side's install and 41 MiB of memory, measured above. And an operator step after every restart: Vault comes back sealed, the MCP server can get no credential, and within a minute the records tool stops, fail closed, until three shares unseal it. One replica: a node lost with Vault on it stops the records tool until the node and an unseal are back. The node-loss drill (ADR 20) does not watch the records tool, and this record does not claim it survives a node.
- **The key set is a snapshot.** A cluster that lives longer than a day runs `scripts/vault.sh keys` once a day, or opens a second path into Vault for the records service, which this record does not do.
- **The licence.** Vault Community is under the Business Source License 1.1. The image's own `LICENSE.txt`, read 2026-11-04 from `hashicorp/vault:2.2.1` (sha256 `45f5550c…67da64`), names IBM as licensor, and its Additional Use Grant allows any use but offering Vault to third parties, hosted or embedded, in competition with IBM's paid versions. It has no clause on benchmarks, and the image carries no other licence file. The repository stays MIT, and README's License section says which component is not.
- **The cloud legs are not changed by this record.** They run `scripts/tools.sh` too. EKS needs a StorageClass for Vault's volume (the run's cluster has no EBS CSI driver), and GKE's default class is unproven in its private cluster. Until the maintainer agrees to that change and its cost, this stays on a branch, or on main with the cloud workflows told apart.
- Vault Enterprise's identity features for agents are documented, not measured.

## Alternatives

- **The projected token, checked by the records service** (the runner-up, above). No new component and no unseal. It gives ten minutes at the least, no way to stop one caller without stopping its workload, and an accept rule in the records service's code. If the records service were the only consumer and ten minutes were acceptable, this would be the choice.
- **A Vault token, checked by lookup** (shape b). Revocation would be immediate, but the records service would need a path into Vault and a call per request, and it would be handed a Vault token, a credential for Vault itself, by every caller. Introspection (`identity/oidc/introspect`) gives the same immediacy and needs the same path, plus a Vault token of the records service's own.
- **The static key, kept in Vault's KV store and rotated.** Still one shared key with no caller in it, and both services would need a way into Vault.
- **A service mesh's workload identity (mTLS).** Strong per-caller identity on every connection, and an Istio-sized install under every workload (ADR 11 turned it down for the same reason).

## How to explain this to a customer

The assistant's tools reach your records service with a pass that lasts one minute, not with a password that lasts forever. The pass is issued by Vault, inside the same closed network, and only to the one program that is allowed to hold it. Your records service checks every pass itself, without calling anyone. If you think that program has been compromised, one command stops Vault from issuing it another pass, and the last one runs out within a minute. The program's other tools keep working. Vault itself has to be unlocked by three of five people after a restart, and until then the records tool is off rather than open.
