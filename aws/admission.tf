# Kyverno reads the models' signatures and AI-BOMs from ECR as itself (ADR 18,
# phase 2): an IAM role for its admission controller's service account,
# through EKS Pod Identity, that may read this run's repositories and nothing
# else. No key anywhere, and not the node's role: a pod cannot reach the
# node's metadata (IMDSv2, one hop), and the node role pulls for the kubelet
# alone. The trust is aws-eks-reference-platform's (its ADR 3).

resource "aws_iam_role" "kyverno" {
  name                 = "${var.cluster_name}-kyverno"
  permissions_boundary = var.iam_permissions_boundary
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "kyverno" {
  name = "read-this-runs-images"
  role = aws_iam_role.kyverno.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # A registry credential is asked for account-wide; what it can read
        # is the next statement.
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability", "ecr:DescribeImages", "ecr:ListImages"]
        Resource = "arn:${local.partition}:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/${var.cluster_name}/*"
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "kyverno" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kyverno"
  service_account = "kyverno-admission-controller"
  role_arn        = aws_iam_role.kyverno.arn
}
