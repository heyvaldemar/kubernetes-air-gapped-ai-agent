# 18. The boundary on AWS: a VPC with no route out, and no name lookup out

- Status: accepted for phase 1, 2026-10-21; phase 2 proposed
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

**Phase 2: the agent on it.** Kyverno, the signed models and their AI-BOMs, the gateway, the MCP server and the evals, on the Phase 1 boundary, with the registry inside being ECR. The policies name the registry today (`registry.boundary.internal:5000`); Phase 2 renders them for the run's registry instead.

**The run** (`.github/workflows/aws.yml`): weekly and by hand, on main only, in the `aws-validation` environment, behind the repository variable `AWS_VALIDATION_ENABLED`, with GitHub's OIDC token for the creation role and no stored credential. One Terraform state per run in the account's state bucket under its own prefix, `airgap-runs/`, so the other repository's sweeper never reads it; the run destroys what it made, looks for residue by its tag, and reports what it cost. A run first destroys any of its own states older than three hours that an earlier run left.

## Phase 1 on AWS, 2026-10-21

Three runs by hand, each destroyed afterwards with nothing left by tag or name:

- [39624648738](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39624648738): the node never joined. All three add-ons waited for the node group, and a node is never Ready without the network plugin; EKS gave up on it as unhealthy. The plugin and kube-proxy now go on before the node, CoreDNS after. About $0.26.
- [39632816543](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39632816543), the DNS check shown its violation, `dns_firewall = false`: everything else held. A pod started from the run's ECR through the endpoints; the pod and the node resolved ECR's name to an address inside the VPC and reached it on 443; neither could open TCP to 1.1.1.1, 8.8.8.8 or 151.101.0.81, or ask 8.8.8.8 directly. And both resolved example.com: a VPC with no internet gateway and no NAT still let a name lookup out. About $0.11.
- [39636241165](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/39636241165), the firewall on: all 16 checks passed, the pod and the node refused example.com, every control answered. About $0.11, 0.37 h.

The schedule is on from here (`AWS_VALIDATION_ENABLED`). The README says weekly once a scheduled run has passed, as `aws-eks-reference-platform` held its own word back.

## Consequences

- About $0.11 a passing run, measured (0.37 h); the estimate was $0.30 to $0.50: the EKS control plane, one node, five interface endpoints in two zones for under an hour, and the DNS Firewall's queries. Weekly, under the $5 a month the maintainer set.
- No KMS key for Secrets here: a key cannot be deleted sooner than seven days, so a weekly run would keep paying for keys it no longer uses, and envelope encryption is shown in `aws-eks-reference-platform`.
- The operator's public endpoint is a way in, from one address, for the length of a run. A site whose operator sits inside would turn public access off and reach the API from the VPC.
- Allowing the region's AWS service zone in DNS lets a workload resolve any AWS endpoint name in the region, which is how the endpoints work; it does not give it a route to anything without an endpoint.

## Alternatives

- **No DNS Firewall, trusting the absence of routes.** The gap this record exists to close.
- **An AWS Network Firewall.** It inspects traffic that has a route; here nothing has one, and it does not see the VPC resolver's queries. Several times the cost for nothing the route table does not already do.
- **A private hosted zone that answers `.` for everything.** It breaks the AWS endpoint names the nodes need, unless every one is recreated by hand.
- **Fully private EKS, the operator inside the VPC.** The right shape for a site; here it would need a bastion or a runner in the VPC, and a way in for that, for a weekly test.

## How to explain this to a customer

In your AWS account, the cluster gets a network with no way to the internet: no gateway, no public address, and its own private doors to the few AWS services it needs. We also close the door most designs leave open. Even with no route out, a cloud network answers questions about any name on the internet, and data can leave inside those questions. Here the network refuses to look up anything outside AWS, and a weekly test on a real AWS account shows both: that nothing gets out, and that it would have, without that rule.
