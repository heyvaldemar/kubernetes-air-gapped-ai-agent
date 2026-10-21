# The boundary on AWS (ADR 18), one run at a time: everything here is made by
# a run and destroyed by it, in the validation account's region.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      "airgap.heyvaldemar.com/project" = "kubernetes-air-gapped-ai-agent"
      "airgap.heyvaldemar.com/cluster" = var.cluster_name
      "run-id"                         = var.run_id
      "managed-by"                     = "terraform"
    }
  }
}
