variable "region" {
  description = "The validation account's one region."
  type        = string
  default     = "us-east-1"
}

variable "run_id" {
  description = "The GitHub run that owns everything here, for the tags and the name."
  type        = string
}

variable "cluster_name" {
  description = <<-EOT
    The cluster's name, and the prefix of every IAM role it makes. The
    validation account lets a run create and change roles only under
    reference-platform (its guardrails), so this starts with that.
  EOT
  type        = string

  validation {
    condition     = can(regex("^reference-platform-airgap-[a-z0-9-]{1,30}$", var.cluster_name))
    error_message = "cluster_name is reference-platform-airgap-<run>, the prefix the account's guardrails allow roles under."
  }
}

variable "kubernetes_version" {
  description = "EKS's Kubernetes version, the one kind runs in the e2e."
  type        = string
  default     = "1.37"
}

variable "vpc_cidr" {
  description = "The VPC's range. Nothing outside it is routed."
  type        = string
  default     = "10.42.0.0/16"
}

variable "operator_cidrs" {
  description = "Where the operator reaches the cluster's API from: the runner's own address, /32, for the length of a run."
  type        = list(string)

  validation {
    condition     = length(var.operator_cidrs) > 0 && alltrue([for c in var.operator_cidrs : endswith(c, "/32")])
    error_message = "operator_cidrs holds single addresses (/32): the API is never open to a range."
  }
}

variable "iam_permissions_boundary" {
  description = "The account's permissions boundary, which every role a run makes must carry."
  type        = string
}

variable "node_instance_type" {
  description = <<-EOT
    The one node's instance type: m7i.large for the boundary alone, and
    m7i.xlarge with the agent, four vCPUs as the GitHub runner the kind e2e
    measures the model on has, so the two runs' numbers compare.
  EOT
  type        = string
  default     = "m7i.large"

  validation {
    condition     = contains(["m7i.large", "m7i.xlarge"], var.node_instance_type)
    error_message = "node_instance_type is m7i.large or m7i.xlarge, the two scripts/aws.sh cost prices."
  }
}

variable "dns_firewall" {
  description = <<-EOT
    Whether the VPC's resolver refuses names outside AWS. Off only to show the
    DNS check its violation (ADR 18): with it off, a pod with no route out
    still resolves example.com.
  EOT
  type        = bool
  default     = true
}

variable "images" {
  description = <<-EOT
    The ECR repositories this run makes, by the image's original path
    (docker.io/library/busybox), each under the cluster's name: every one the
    bundle carries with the agent (scripts/aws.sh repositories), busybox's
    alone for the boundary.
  EOT
  type        = list(string)
  default     = ["docker.io/library/busybox"]

  validation {
    condition     = alltrue([for i in var.images : can(regex("^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$", i))])
    error_message = "every image is a repository path ECR accepts: lower case, by its original host and path."
  }
}
