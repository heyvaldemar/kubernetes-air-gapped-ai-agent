# NO NAME LOOKUP OUT (ADR 18). A VPC's resolver answers any name on the
# internet whatever the routes say, and a query carries whatever a workload
# puts in the name to whoever answers for it. With no route out, DNS is the
# way out left. This rule group answers the region's AWS service names and
# the VPC's own internal names, which AWS's servers answer, and refuses
# everything else with NXDOMAIN; fail-open is off, so a firewall that cannot
# decide refuses too.

resource "aws_route53_resolver_firewall_domain_list" "aws" {
  name = "${var.cluster_name}-aws"
  domains = [
    "amazonaws.com",
    "*.amazonaws.com",
    "ec2.internal",
    "*.ec2.internal",
    "compute.internal",
    "*.compute.internal",
  ]
}

resource "aws_route53_resolver_firewall_domain_list" "everything" {
  name    = "${var.cluster_name}-everything"
  domains = ["*"]
}

resource "aws_route53_resolver_firewall_rule_group" "this" {
  name = var.cluster_name
}

resource "aws_route53_resolver_firewall_rule" "allow_aws" {
  name                    = "allow-aws"
  action                  = "ALLOW"
  firewall_domain_list_id = aws_route53_resolver_firewall_domain_list.aws.id
  firewall_rule_group_id  = aws_route53_resolver_firewall_rule_group.this.id
  priority                = 100
}

resource "aws_route53_resolver_firewall_rule" "block_everything_else" {
  name                    = "block-everything-else"
  action                  = "BLOCK"
  block_response          = "NXDOMAIN"
  firewall_domain_list_id = aws_route53_resolver_firewall_domain_list.everything.id
  firewall_rule_group_id  = aws_route53_resolver_firewall_rule_group.this.id
  priority                = 200
}

# Associated only when dns_firewall is true: the one run that shows the DNS
# check its violation leaves it off (ADR 18).
resource "aws_route53_resolver_firewall_rule_group_association" "this" {
  count                  = var.dns_firewall ? 1 : 0
  name                   = var.cluster_name
  firewall_rule_group_id = aws_route53_resolver_firewall_rule_group.this.id
  vpc_id                 = aws_vpc.this.id
  priority               = 101
}

resource "aws_route53_resolver_firewall_config" "this" {
  resource_id        = aws_vpc.this.id
  firewall_fail_open = "DISABLED"
}
