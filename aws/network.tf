# A VPC with no way out (ADR 18). No internet gateway and no NAT gateway are
# declared anywhere in this directory, and static check "aws" fails if one
# is. Each private subnet's route table holds the VPC's own range, which AWS
# adds itself, and the S3 gateway endpoint's prefix list. Nothing else.

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs     = slice(data.aws_availability_zones.available.names, 0, 2)
  subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  # What the nodes and pods reach in AWS, each through an interface endpoint
  # in the VPC: the image registry (its API and its Docker endpoint), STS,
  # EC2 for the node's own bootstrap, EKS, and EKS Auth, where the Pod
  # Identity agent gets Kyverno its role's credential.
  interface_endpoints = ["ecr.api", "ecr.dkr", "sts", "ec2", "eks", "eks-auth"]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.cluster_name }
}

# The default security group allows all traffic between its members. Nothing
# uses it; with no rules, nothing can by accident.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.cluster_name}-default-unused" }
}

resource "aws_subnet" "private" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.subnets[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.cluster_name}-private-${local.azs[count.index]}" }
}

resource "aws_route_table" "private" {
  count  = length(local.azs)
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.cluster_name}-private-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "private" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ECR keeps image layers in S3, so the nodes reach S3 too: through a gateway
# endpoint, a prefix list in the route tables, at no cost.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id
  tags              = { Name = "${var.cluster_name}-s3" }
}

resource "aws_security_group" "endpoints" {
  name        = "${var.cluster_name}-endpoints"
  description = "The interface endpoints answer HTTPS from inside the VPC, and nothing else."
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.cluster_name}-endpoints" }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id = aws_security_group.endpoints.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS from the VPC"
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(local.interface_endpoints)
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  tags                = { Name = "${var.cluster_name}-${each.value}" }
}
