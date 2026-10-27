variable "project" {
  description = "The validation project, which holds nothing but these runs."
  type        = string
}

variable "region" {
  description = "The project's one region."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "The zone of the cluster and its one node: a zonal cluster, the one GKE's free tier covers."
  type        = string
  default     = "us-central1-a"

  validation {
    condition     = startswith(var.zone, "${var.region}-")
    error_message = "zone is in the project's one region."
  }
}

variable "run_id" {
  description = "The GitHub run that owns everything here, for the labels and the name."
  type        = string
}

variable "cluster_name" {
  description = "The cluster's name, and the name of everything the run makes beside it."
  type        = string

  validation {
    condition     = can(regex("^airgap-[0-9a-z]([0-9a-z-]{0,28}[0-9a-z])?$", var.cluster_name))
    error_message = "cluster_name is airgap-<run>: the sweep finds what a run left by that prefix."
  }
}

variable "kubernetes_version" {
  description = "GKE's Kubernetes version, the one kind runs in the e2e and EKS runs on AWS."
  type        = string
  default     = "1.37"
}

variable "release_channel" {
  description = "The GKE release channel the version comes from: Regular, which has offered 1.37 since 2026-10-22."
  type        = string
  default     = "REGULAR"
}

variable "vpc_cidr" {
  description = <<-EOT
    The range every address in the network comes from: the nodes, the pods
    and the services. A VPC on Google Cloud has no range of its own; this is
    the one its subnet and the egress firewall are cut from.
  EOT
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

variable "node_service_account" {
  description = "The nodes' service account (gke/bootstrap), which has no role in the project; the run lets it read the run's registry."
  type        = string

  validation {
    condition     = can(regex("^airgap-node@[a-z0-9-]+\\.iam\\.gserviceaccount\\.com$", var.node_service_account))
    error_message = "the nodes run as the bootstrap's airgap-node account and no other."
  }
}

variable "node_machine_type" {
  description = <<-EOT
    The one node's machine type: e2-standard-2 for the boundary alone, and
    c3d-standard-4 with the agent, four vCPUs as the GitHub runner the kind
    e2e measures the model on has, on AMD EPYC as the runner's are.
  EOT
  type        = string
  default     = "e2-standard-2"

  validation {
    condition     = contains(["e2-standard-2", "c3d-standard-4"], var.node_machine_type)
    error_message = "node_machine_type is e2-standard-2 or c3d-standard-4, the two scripts/gke.sh cost prices."
  }
}

variable "dns_firewall" {
  description = <<-EOT
    Whether the network's resolver refuses names outside Google's APIs and
    the VPC's own. Off only to show the DNS check its violation (ADR 22): with
    it off, a pod with no route out still resolves example.com.
  EOT
  type        = bool
  default     = true
}
