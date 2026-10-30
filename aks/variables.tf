variable "location" {
  description = "The subscription's one region for these runs."
  type        = string
  default     = "eastus"
}

variable "run_id" {
  description = "The GitHub run that owns everything here, for the tags and the names."
  type        = string
}

variable "cluster_name" {
  description = "The cluster's name, its resource group's, and the stem of everything the run makes."
  type        = string

  validation {
    condition     = can(regex("^airgap-[0-9]{6,20}$", var.cluster_name))
    error_message = "cluster_name is airgap-<run>: the sweep finds what a run left by that name."
  }
}

variable "kubernetes_version" {
  description = "AKS's Kubernetes version, the one kind runs in the e2e, EKS on AWS and GKE on Google Cloud."
  type        = string
  default     = "1.37"
}

variable "vpc_cidr" {
  description = "The virtual network's range: the nodes, the API server's subnet and the registry's private endpoint."
  type        = string
  default     = "10.42.0.0/16"
}

variable "pod_cidr" {
  description = "The pods' overlay range, outside the virtual network: a pod's traffic leaves its node with the node's address."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "The services' range, outside the virtual network and the pods'."
  type        = string
  default     = "10.245.0.0/16"
}

variable "operator_cidrs" {
  description = "Where the operator reaches the cluster's API and the registry from: the runner's own address, /32, for the length of a run."
  type        = list(string)

  validation {
    condition     = length(var.operator_cidrs) > 0 && alltrue([for c in var.operator_cidrs : endswith(c, "/32")])
    error_message = "operator_cidrs holds single addresses (/32): the API and the registry are never open to a range."
  }
}

variable "identity_resource_group" {
  description = "Where aks/bootstrap.sh keeps the cluster's and the kubelet's standing identities."
  type        = string
  default     = "airgap-identities"
}

variable "node_vm_size" {
  description = <<-EOT
    The one node's size: Standard_D2as_v7 for the boundary alone, and
    Standard_D4as_v7 with the agent, four vCPUs as the GitHub runner the kind
    e2e measures the model on has, on AMD EPYC as the runner's are. The trial
    subscription allows four vCPUs in the region in all, so one node and no
    second (ADR 23).
  EOT
  type        = string
  default     = "Standard_D2as_v7"

  validation {
    condition     = contains(["Standard_D2as_v7", "Standard_D4as_v7"], var.node_vm_size)
    error_message = "node_vm_size is Standard_D2as_v7 or Standard_D4as_v7, the two scripts/aks.sh cost prices."
  }
}

variable "dns_firewall" {
  description = <<-EOT
    Whether the network's resolver refuses every name outside the registry's
    and the network's own. Off only to show the DNS check its violation (ADR
    23): with it off, a pod with no route out still resolves example.com.
  EOT
  type        = bool
  default     = true
}
