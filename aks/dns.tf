# NO NAME LOOKUP OUT (ADR 23). Every VM in an Azure virtual network resolves
# through Azure's DNS, 168.63.129.16, which answers any name on the internet
# whatever the network security group says; a query carries whatever a
# workload puts in the name to whoever answers for that name. With no route
# out, DNS is the way out left, as it was on AWS (ADR 18) and Google Cloud
# (ADR 22).
#
# A DNS resolver policy on the network closes it: Azure's DNS refuses every
# name ("." matches all of them) but the ones the cluster needs, which a rule
# of higher priority lets through, with every name under them:
#
#   azurecr.io.             the registry's names; the private zone
#                           privatelink.azurecr.io (registry.tf) answers them
#                           with the private endpoint's addresses
#   internal.cloudapp.net.  the network's own names for its VMs, which Azure
#                           answers and no outside party reads
#
# The nodes reach the API server at its private address, not by name (API
# Server VNet Integration). A rule follows a CNAME chain: a name whose chain
# passes through a refused name is refused, and one that ends under an
# allowed name is let through.

locals {
  allowed_names = ["azurecr.io.", "internal.cloudapp.net."]
  refused_names = ["."]
}

resource "azapi_resource" "dns_policy" {
  type      = "Microsoft.Network/dnsResolverPolicies@2025-05-01"
  name      = var.cluster_name
  parent_id = azurerm_resource_group.this.id
  location  = var.location
  tags      = local.tags
}

resource "azapi_resource" "allowed" {
  type      = "Microsoft.Network/dnsResolverDomainLists@2025-05-01"
  name      = "${var.cluster_name}-allowed"
  parent_id = azurerm_resource_group.this.id
  location  = var.location
  tags      = local.tags
  body = {
    properties = { domains = local.allowed_names }
  }
}

resource "azapi_resource" "refused" {
  type      = "Microsoft.Network/dnsResolverDomainLists@2025-05-01"
  name      = "${var.cluster_name}-refused"
  parent_id = azurerm_resource_group.this.id
  location  = var.location
  tags      = local.tags
  body = {
    properties = { domains = local.refused_names }
  }
}

resource "azapi_resource" "allow" {
  type      = "Microsoft.Network/dnsResolverPolicies/dnsSecurityRules@2025-05-01"
  name      = "allow"
  parent_id = azapi_resource.dns_policy.id
  location  = var.location
  tags      = local.tags
  body = {
    properties = {
      priority               = 100
      action                 = { actionType = "Allow" }
      dnsResolverDomainLists = [{ id = azapi_resource.allowed.id }]
      dnsSecurityRuleState   = "Enabled"
    }
  }
}

resource "azapi_resource" "refuse" {
  type      = "Microsoft.Network/dnsResolverPolicies/dnsSecurityRules@2025-05-01"
  name      = "refuse"
  parent_id = azapi_resource.dns_policy.id
  location  = var.location
  tags      = local.tags
  body = {
    properties = {
      priority               = 200
      action                 = { actionType = "Block" }
      dnsResolverDomainLists = [{ id = azapi_resource.refused.id }]
      dnsSecurityRuleState   = "Enabled"
    }
  }
}

# On the network only when dns_firewall is true: the one run that shows the
# DNS check its violation leaves it off (ADR 23).
resource "azapi_resource" "dns_policy_link" {
  count     = var.dns_firewall ? 1 : 0
  type      = "Microsoft.Network/dnsResolverPolicies/virtualNetworkLinks@2025-05-01"
  name      = var.cluster_name
  parent_id = azapi_resource.dns_policy.id
  location  = var.location
  tags      = local.tags
  body = {
    properties = {
      virtualNetwork = { id = azurerm_virtual_network.this.id }
    }
  }
  depends_on = [azapi_resource.allow, azapi_resource.refuse]
}
