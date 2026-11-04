# Vault's volume (ADR 24): the EBS CSI driver, as an EKS add-on beside
# coredns, with an IAM role of its own through EKS Pod Identity, as Kyverno
# has (admission.tf). The driver reaches EC2 through the VPC's endpoint and
# its images come from EKS's own ECR in the region, as coredns's do.
#
# A volume the driver makes is in no Terraform state, so the destroy does
# not take it away. The run deletes Vault's claim before the destroy
# (scripts/vault.sh release), every volume the driver makes carries the
# run's tags so `aws.sh residue` sees one left behind, and `aws.sh sweep`
# deletes one an earlier run left. The StorageClass, gp3 and encrypted, is
# aws/storage-class.yaml.

locals {
  # The tags the driver writes on every volume it makes: the provider's
  # default_tags do not reach what Kubernetes creates.
  volume_tags = {
    "airgap.heyvaldemar.com/project" = "kubernetes-air-gapped-ai-agent"
    "airgap.heyvaldemar.com/cluster" = var.cluster_name
  }
}

resource "aws_iam_role" "ebs_csi" {
  name                 = "${var.cluster_name}-ebs-csi"
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

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
}
