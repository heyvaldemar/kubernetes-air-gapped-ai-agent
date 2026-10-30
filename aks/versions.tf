# The boundary on AKS (ADR 23), one run at a time: everything here is made by
# a run, in a resource group of its own, and goes with that group's one
# delete. The subscription's standing parts (the two identities GitHub
# federates to, the cluster's and the kubelet's identities, the state
# account, the budget) are made once by the maintainer: aks/bootstrap.sh.
terraform {
  required_version = ">= 1.10"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.10.0"
    }
    # A DNS resolver policy, and a registry's cache rule under the name AKS
    # requires (aks-managed-mcr, which azurerm's name check refuses), are
    # Azure API resources azurerm does not model.
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.13.0"
    }
  }
}

locals {
  tags = {
    "airgap-project" = "kubernetes-air-gapped-ai-agent"
    "airgap-cluster" = var.cluster_name
    "run-id"         = var.run_id
    "managed-by"     = "terraform"
  }
}

# The creation identity is Contributor and nothing else: it registers no
# resource provider (the maintainer did, once).
provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  resource_provider_registrations = "none"
}

provider "azapi" {}
