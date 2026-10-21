# EKS in the closed VPC (ADR 18). The nodes reach the API through its private
# endpoint; the operator, the runner, through the public one from its own
# address only. Access entries only, no aws-auth ConfigMap, and the creator
# is not an administrator by default: the run's own role is given that
# explicitly. No KMS key for Secrets: a key lives at least seven days after a
# run deletes it, and envelope encryption is shown in aws-eks-reference-platform.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

locals {
  partition = data.aws_partition.current.partition
}

resource "aws_iam_role" "cluster" {
  name                 = "${var.cluster_name}-cluster"
  permissions_boundary = var.iam_permissions_boundary
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.operator_cidrs
  }

  upgrade_policy {
    support_type = "STANDARD"
  }

  bootstrap_self_managed_addons = false

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

resource "aws_eks_access_entry" "operator" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = data.aws_iam_session_context.current.issuer_arn
}

resource "aws_eks_access_policy_association" "operator" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.operator.principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
}

# The add-ons EKS manages: their images come from AWS's own registries in the
# region, through the ECR endpoints. The network plugin and kube-proxy go on
# before the node, which is never Ready without them: the first run on AWS
# made all three wait for the node, and EKS gave up on it as unhealthy
# (run 39624648738). CoreDNS goes on after, since it needs a node to run on.
resource "aws_eks_addon" "before_nodes" {
  for_each                    = toset(["vpc-cni", "kube-proxy"])
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "after_nodes" {
  for_each                    = toset(["coredns"])
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.this]
}
