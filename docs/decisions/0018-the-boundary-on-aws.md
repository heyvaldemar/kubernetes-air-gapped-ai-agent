# 18. The boundary on AWS: a VPC with no route out, and no name lookup out

- Status: accepted for phase 1, 2026-10-21, and phase 2, 2026-10-22
- Date: 2026-10-21

## Context

Everything this repository proves, it proves on kind on a GitHub runner, where the boundary is the host's firewall and the node's resolver (ADR 1). A buyer runs it in a cloud account, and the questions there are different ones. What does "no way out" mean in a VPC? Which AWS services must the cluster still reach, and through what? Does the boundary hold when the network is AWS's and not the runner's?

The obvious answer, a VPC with no internet gateway and no NAT gateway, is incomplete. Every VPC has the Route 53 Resolver at the base of its range, and it answers queries for any name on the internet, whatever the routes say. A workload with no route out can still put data into the names it looks up, and the authoritative servers for those names, anybody's, receive it. DNS is a way out that a route table does not close.

The maintainer said yes on 2026-10-21 to this running weekly in the validation account `aws-eks-reference-platform` set up (its ADR 10), up to $5 a month, under the same guardrails, permissions boundary, budgets and $30 kill-switch; that account's creation role now trusts this repository's `aws-validation` environment too (bootstrap `also_create`).

## Decision

In two phases, the first proven before the second is built.

**Phase 1: the boundary itself.** `aws/` is Terraform for one run:

- **A VPC with private subnets only**, in two zones: no internet gateway, no NAT gateway, no public IP anywhere. Each route table holds the VPC's own range and the S3 gateway endpoint's prefix list, and nothing else.
- **What the cluster must reach in AWS, reached privately**: interface endpoints for ECR (`ecr.api`, `ecr.dkr`), STS and EC2, and the S3 gateway endpoint ECR's layers come through, each answering on 443 from the VPC's range only.
- **No name lookup out**: a Route 53 Resolver DNS Firewall rule group, associated with the VPC with fail-open off, answers names in this region's AWS service zone and the VPC's own internal zones and refuses everything else with NXDOMAIN. Those zones are answered by AWS's own servers, which no outside party reads.
- **EKS whose API the operator reaches and nothing else does**: private endpoint access for the nodes; public access for the operator, the runner, at its own address only (`/32`). One managed node group, one node.
- **Images across the gap into ECR**: the runner, on the connected side, verifies what it brings and copies it into this run's ECR repositories by digest; the nodes pull from there through the endpoints.

`tests/e2e/aws.sh` runs the boundary checks the kind e2e runs, each refusal beside a control from the same pod: no TCP to the internet by address; no answer for a public name, while this region's ECR endpoint name and the cluster's own services resolve; ECR reachable on 443 through its endpoint. The DNS check is shown its violation once, on a run with the firewall's association left out (`dns_firewall = false`), before it is trusted.

**Phase 2: the agent on it.** Kyverno, the signed model and its AI-BOM, the gateway, the MCP server and the evals, on the Phase 1 boundary, with the registry inside being ECR:

- **The same signed file crosses.** The runner, the connected side, builds the model reproducibly, signs it, attests its AI-BOM and makes the plants against a staging registry of its own, then carries everything the cluster runs in one signed file, as the kind e2e does. The staging registry is gone before the file crosses. `scripts/bundle.sh load` verifies the signature and every checksum, then copies each image into the run's ECR repositories, which Terraform made empty, one per image the file carries, under its original path.
- **Every image is named under the registry inside.** On kind the node's containerd serves `docker.io/library/python` from the registry inside by a mirror rule. ECR needs a credential, and a mirror rule cannot give containerd one, so here every manifest, chart and policy names its image under the run's ECR path by the same path and digest (`scripts/inside.sh`), and the kubelet pulls with the node's role. The policies name the models path there; the digests are the ones the file carried, so `carried-images` is unchanged.
- **Kyverno reads signatures as itself.** An IAM role for the admission controller's service account, through EKS Pod Identity, that may read this run's repositories and nothing else (`aws/admission.tf`); the model policy names the `amazon` credential provider. The Pod Identity agent gets that credential from EKS Auth, through a sixth endpoint, and the resolver allows EKS Auth's one name, which is outside `amazonaws.com`.
- **The agent's NetworkPolicies are enforced.** The VPC CNI enforces them itself only with `enableNetworkPolicy`; without it they would be accepted and enforce nothing.
- **Nothing asks for a load balancer.** The gateway's Service is ClusterIP. Its default, a LoadBalancer, is what a cloud account builds one for: a way in from outside.

`tests/e2e/run.sh` with `CHECKS=inside` runs the e2e's checks on what is inside: the plants, the registry holding exactly what the file carried, a file changed by one byte refused, nothing running that it did not carry. Then the boundary's 16, the evals at the release gates, and the game day. With the agent the node is an m7i.xlarge, the GitHub runner's four vCPUs.

**The run** (`.github/workflows/aws.yml`): weekly and by hand, on main only, in the `aws-validation` environment, behind the repository variable `AWS_VALIDATION_ENABLED`, with GitHub's OIDC token for the creation role and no stored credential. One Terraform state per run in the account's state bucket under its own prefix, `airgap-runs/`, so the other repository's sweeper never reads it; the run destroys what it made, looks for residue by its tag, and reports what it cost. A run first destroys any of its own states older than three hours that an earlier run left. The residue check also looks for what no state holds: anything with the project's tag and another run's cluster tag that EC2, ECR or EKS says still exists fails the run, since run 39898005905's check listed a subnet under its cluster's tag that EC2 never had (the tagging API's record of a throttled CreateSubnet, by CloudTrail).

## Phase 1 on AWS, 2026-10-21

Three runs by hand, each destroyed afterwards with nothing left by tag or name:

- [39624648738](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39624648738): the node never joined. All three add-ons waited for the node group, and a node is never Ready without the network plugin; EKS gave up on it as unhealthy. The plugin and kube-proxy now go on before the node, CoreDNS after. About $0.26.
- [39632816543](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39632816543), the DNS check shown its violation, `dns_firewall = false`: everything else held. A pod started from the run's ECR through the endpoints; the pod and the node resolved ECR's name to an address inside the VPC and reached it on 443; neither could open TCP to 1.1.1.1, 8.8.8.8 or 151.101.0.81, or ask 8.8.8.8 directly. And both resolved example.com: a VPC with no internet gateway and no NAT still let a name lookup out. About $0.11.
- [39636241165](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39636241165), the firewall on: all 16 checks passed, the pod and the node refused example.com, every control answered. About $0.11, 0.37 h.

The schedule is on from here (`AWS_VALIDATION_ENABLED`). The README says weekly once a scheduled run has passed, as `aws-eks-reference-platform` held its own word back.

## Phase 2 on AWS, 2026-10-22

[39700915485](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39700915485), by hand: all 56 checks passed, nothing was left behind, about $0.30 for 0.72 h.

- The file, 24 image tags and 3.5 GB, verified and loaded into repositories that held nothing; ECR then held exactly the 24, by digest, and the same file with one byte changed was refused. The 10 pods outside `kube-system` all ran images it carried.
- Admission admitted the signed model and the one whose licence expression was concluded to an allowed id, and refused the eleven plants the kind e2e refuses: weights nobody signed, weights another key signed, a model with no AI-BOM, three AI-BOMs listing a licence the site does not allow or a model with none, an SPDX expression, a model and an image by tag, weights from outside the models path, and an image the file never carried. Every signature and AI-BOM among them was read from ECR by Kyverno, with its own role. The kubelet mounted the model from ECR as an image volume.
- The boundary's 16 held as in phase 1.
- The evals at the release gates: 18 of 18 ordinary tasks; no email delivered outside acme.example, no record deleted; 157 model requests asked by the agent and 157 answered by the gateway, and 93,230 tokens counted on both sides.
- The game day: Kyverno at zero took its webhook for `verify-models` with it (7 configurations to 2), and the guard refused a model nobody signed, one under a licence the site does not allow and the signed model, while the model already served answered; 35 s after Kyverno was back the signed model was admitted. The gateway's pod killed: the model server still unreachable around it (an agent NetworkPolicy, enforced by the VPC CNI), the gateway answering 13 s later, one request lost. The model server rolled forward and back under traffic: 130 of 130 answered each way, and each long answer in flight was finished.

One number moved, and the record says what changed: the same model on the same two threads answered at half the rate, p50 5.4 s a task against 2.7 s on the GitHub runner (run 39644276886). The runner's processor was an AMD EPYC 9V45, the node's an m7i's. `tests/e2e/aws.sh` now prints the node's processor, and a sizing is read against the node it was measured on. The README's Sizing figures are the runner's.

The schedule runs phase 2 from here (`AWS_AGENT_ENABLED`). Its first run, [39744285464](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39744285464), created at 07:58 UTC for the 02:47 cron, passed all 56 checks the same day, about $0.29 for 0.69 h, with nothing left behind. The node's processor was an Intel Xeon Platinum 8488C, and the model's p50 was 5.5 s a task: the half rate is the node's, not the run's. Weekly on AWS from 22 October 2026.

## Consequences

- About $0.11 a passing run of the boundary alone, measured (0.37 h); the estimate was $0.30 to $0.50: the EKS control plane, one node, five interface endpoints in two zones for under an hour, and the DNS Firewall's queries. With the agent, about $0.30 (0.72 h): an m7i.xlarge, a sixth endpoint, and the evals and the game day. Weekly, about $1.30 a month, under the $5 the maintainer set.
- The account's ID is in the run's ECR path, so it is in the run's public log. AWS does not treat an account ID as a secret; nothing here relies on it being unknown.
- No KMS key for Secrets here: a key cannot be deleted sooner than seven days, so a weekly run would keep paying for keys it no longer uses, and envelope encryption is shown in `aws-eks-reference-platform`.
- The operator's public endpoint is a way in, from one address, for the length of a run. A site whose operator sits inside would turn public access off and reach the API from the VPC.
- Allowing the region's AWS service zone in DNS lets a workload resolve any AWS endpoint name in the region, which is how the endpoints work; it does not give it a route to anything without an endpoint.

## Alternatives

- **No DNS Firewall, trusting the absence of routes.** The gap this record exists to close.
- **An AWS Network Firewall.** It inspects traffic that has a route; here nothing has one, and it does not see the VPC resolver's queries. Several times the cost for nothing the route table does not already do.
- **A private hosted zone that answers `.` for everything.** It breaks the AWS endpoint names the nodes need, unless every one is recreated by hand.
- **Fully private EKS, the operator inside the VPC.** The right shape for a site; here it would need a bastion or a runner in the VPC, and a way in for that, for a weekly test.
- **For phase 2, a containerd mirror into ECR, as on kind.** The node's containerd would send `docker.io` to ECR, which refuses it: a mirror rule carries no credential, and the kubelet's credential provider answers for ECR's own names only.
- **Kyverno with a registry secret: an ECR token in a Secret.** A credential that lives twelve hours, kept in the cluster, renewed by something outside it. The role is renewed by EKS and lives nowhere.
- **Kyverno with the node's role.** A pod cannot reach the node's metadata (IMDSv2, one hop), and if it could, every pod on the node would read what Kyverno reads. IRSA would do; `aws-eks-reference-platform` chose Pod Identity for its controllers (its ADR 3), and this follows it.

## How to explain this to a customer

In your AWS account, the cluster gets a network with no way to the internet: no gateway, no public address, and its own private doors to the few AWS services it needs. We also close the door most designs leave open. Even with no route out, a cloud network answers questions about any name on the internet, and data can leave inside those questions. Here the network refuses to look up anything outside AWS, and a weekly test on a real AWS account shows both: that nothing gets out, and that it would have, without that rule.

The agent runs inside it as it does in our daily test: everything it runs arrives in one signed file and goes into your own registry, the model is admitted only with its signature and its licence record, the checker reads them with an AWS identity of its own that can read nothing else, and the same weekly run takes the checker, the gateway and the model server down while the agent works, and shows each failing closed.
