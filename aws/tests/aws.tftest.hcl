# What the boundary on AWS promises (ADR 18), checked on a plan against a
# mocked AWS provider: no account, no credentials, no cost. Run by static
# check "aws"; what no plan can show (an internet gateway, a NAT gateway or a
# route declared anywhere: a route table's routes are only known after apply)
# the same check reads from the files, and tests/e2e/aws.sh tries on AWS.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:sts::123456789012:assumed-role/platform-validation-create/run" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_session_context" {
    defaults = { issuer_arn = "arn:aws:iam::123456789012:role/platform-validation-create" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b", "us-east-1c"] }
  }
}

variables {
  run_id                   = "12345678901"
  cluster_name             = "reference-platform-airgap-12345678901"
  operator_cidrs           = ["203.0.113.7/32"]
  iam_permissions_boundary = "arn:aws:iam::123456789012:policy/platform-validation-boundary"
}

run "no_route_out" {
  command = plan

  assert {
    condition     = alltrue([for s in aws_subnet.private : s.map_public_ip_on_launch == false])
    error_message = "no subnet gives anything a public address"
  }
  assert {
    condition     = aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway" && length(aws_subnet.private) == 2
    error_message = "two private subnets, and S3 through a gateway endpoint"
  }
}

run "aws_reached_privately" {
  command = plan

  assert {
    condition     = toset(keys(aws_vpc_endpoint.interface)) == toset(["ecr.api", "ecr.dkr", "sts", "ec2", "eks", "eks-auth"])
    error_message = "ECR, STS, EC2, EKS and EKS Auth each through an interface endpoint"
  }
  assert {
    condition     = alltrue([for e in aws_vpc_endpoint.interface : e.private_dns_enabled])
    error_message = "the endpoints answer the services' own names, so nothing needs a public address for them"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.endpoints_https.cidr_ipv4 == "10.42.0.0/16" && aws_vpc_security_group_ingress_rule.endpoints_https.from_port == 443 && aws_vpc_security_group_ingress_rule.endpoints_https.to_port == 443
    error_message = "the endpoints answer HTTPS from the VPC and nothing else"
  }
}

run "no_name_lookup_out" {
  command = plan

  assert {
    condition     = aws_route53_resolver_firewall_rule.block_everything_else.action == "BLOCK" && aws_route53_resolver_firewall_rule.block_everything_else.block_response == "NXDOMAIN"
    error_message = "every name outside the allow list is refused, NXDOMAIN"
  }
  assert {
    condition     = toset(aws_route53_resolver_firewall_domain_list.everything.domains) == toset(["*"])
    error_message = "the refusal covers every name"
  }
  assert {
    condition     = aws_route53_resolver_firewall_rule.allow_aws.priority < aws_route53_resolver_firewall_rule.block_everything_else.priority
    error_message = "the AWS names are allowed before everything else is refused"
  }
  assert {
    condition     = alltrue([for d in aws_route53_resolver_firewall_domain_list.aws.domains : endswith(d, "amazonaws.com") || endswith(d, ".internal") || d == "eks-auth.us-east-1.api.aws"])
    error_message = "the allow list holds AWS's names, the VPC's internal ones and EKS Auth's by its full name, nothing on the open internet"
  }
  assert {
    condition     = length(aws_route53_resolver_firewall_rule_group_association.this) == 1
    error_message = "the rule group is on the VPC by default"
  }
  assert {
    condition     = aws_route53_resolver_firewall_config.this.firewall_fail_open == "DISABLED"
    error_message = "a firewall that cannot decide refuses: fail-open is off"
  }
}

# The one run that shows the DNS check its violation.
run "dns_firewall_off_is_the_violation" {
  command = plan

  variables {
    dns_firewall = false
  }

  assert {
    condition     = length(aws_route53_resolver_firewall_rule_group_association.this) == 0
    error_message = "with dns_firewall off, the rule group is not on the VPC"
  }
}

run "the_api_from_the_operator_only" {
  command = plan

  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].public_access_cidrs == toset(["203.0.113.7/32"]) && aws_eks_cluster.this.vpc_config[0].endpoint_private_access
    error_message = "the API's public endpoint answers the operator's one address; the nodes use the private one"
  }
  assert {
    condition     = aws_eks_cluster.this.access_config[0].authentication_mode == "API" && aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions == false
    error_message = "access entries only, and no administrator by default"
  }
}

run "an_open_api_is_refused" {
  command = plan

  variables {
    operator_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.operator_cidrs]
}

run "every_role_carries_the_boundary" {
  command = plan

  assert {
    condition     = alltrue([for r in [aws_iam_role.cluster, aws_iam_role.node, aws_iam_role.kyverno] : r.permissions_boundary == var.iam_permissions_boundary])
    error_message = "every role a run makes carries the account's permissions boundary"
  }
  assert {
    condition     = alltrue([for r in [aws_iam_role.cluster, aws_iam_role.node, aws_iam_role.kyverno] : startswith(r.name, "reference-platform")])
    error_message = "every role is under the prefix the account's guardrails allow"
  }
}

run "a_name_outside_the_guardrails_is_refused" {
  command = plan

  variables {
    cluster_name = "airgap-12345678901"
  }

  expect_failures = [var.cluster_name]
}

run "the_node" {
  command = plan

  assert {
    condition     = aws_launch_template.node.metadata_options[0].http_tokens == "required" && aws_launch_template.node.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "IMDSv2 only, one hop: a pod cannot read the node's credentials"
  }
  assert {
    condition     = aws_eks_node_group.this.scaling_config[0].max_size == 1
    error_message = "one node"
  }
}

# Phase 2: what the agent needs on top of the boundary.
run "kyverno_reads_this_runs_images_as_itself" {
  command = plan

  assert {
    condition     = jsondecode(aws_iam_role.kyverno.assume_role_policy).Statement[0].Principal.Service == "pods.eks.amazonaws.com"
    error_message = "Kyverno's role is assumed through EKS Pod Identity, by no one else"
  }
  assert {
    condition     = aws_eks_pod_identity_association.kyverno.namespace == "kyverno" && aws_eks_pod_identity_association.kyverno.service_account == "kyverno-admission-controller"
    error_message = "the role goes to the admission controller's service account and no other"
  }
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.kyverno.policy).Statement :
      s.Action == "ecr:GetAuthorizationToken" || s.Resource == "arn:aws:ecr:us-east-1:123456789012:repository/reference-platform-airgap-12345678901/*"
    ])
    error_message = "Kyverno reads this run's repositories and nothing else"
  }
  assert {
    condition = alltrue(flatten([
      for s in jsondecode(aws_iam_role_policy.kyverno.policy).Statement : [
        for a in flatten([s.Action]) : contains(["ecr:GetAuthorizationToken", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability", "ecr:DescribeImages", "ecr:ListImages"], a)
      ]
    ]))
    error_message = "Kyverno's role reads images; it can write, delete or change nothing"
  }
}

run "network_policies_are_enforced" {
  command = plan

  assert {
    condition     = jsondecode(aws_eks_addon.before_nodes["vpc-cni"].configuration_values).enableNetworkPolicy == "true"
    error_message = "the VPC CNI enforces NetworkPolicies; without it the agent's would be accepted and enforce nothing"
  }
  assert {
    condition     = contains(keys(aws_eks_addon.before_nodes), "eks-pod-identity-agent")
    error_message = "the Pod Identity agent is on, before the node"
  }
}

run "the_registry_inside" {
  command = plan

  variables {
    images = ["docker.io/library/busybox", "models/granite-4.0-1b", "ghcr.io/ggml-org/llama.cpp"]
  }

  assert {
    condition     = toset([for r in aws_ecr_repository.this : r.name]) == toset(["reference-platform-airgap-12345678901/docker.io/library/busybox", "reference-platform-airgap-12345678901/models/granite-4.0-1b", "reference-platform-airgap-12345678901/ghcr.io/ggml-org/llama.cpp"])
    error_message = "one repository per image the bundle carries, under the cluster's name by the image's original path"
  }
  assert {
    condition     = alltrue([for r in aws_ecr_repository.this : r.image_tag_mutability == "IMMUTABLE"])
    error_message = "a tag in the registry inside, once loaded, names the same bytes for the rest of the run"
  }
}

run "an_image_ecr_cannot_name_is_refused" {
  command = plan

  variables {
    images = ["Docker.io/library/busybox"]
  }

  expect_failures = [var.images]
}
