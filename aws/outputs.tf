output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "registry" {
  description = "The registry inside: this account's ECR in the region."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "inside" {
  description = "The registry inside for scripts/inside.sh: this run's path in ECR."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/${var.cluster_name}"
}

output "repositories" {
  value = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "dns_firewall" {
  value = var.dns_firewall
}
