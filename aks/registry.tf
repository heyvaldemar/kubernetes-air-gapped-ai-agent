# The registry inside (ADR 23): this run's Azure Container Registry, which the
# node pulls from through a private endpoint in the network, by the names the
# private zone privatelink.azurecr.io answers there with the endpoint's
# addresses. Premium, because a private endpoint and an IP rule need it.
#
# It holds two things, each under its own path:
#
#   aks-managed-repository/  AKS's own images and binaries. A network
#                            isolated cluster bootstraps from here, not from
#                            mcr.microsoft.com: on the first pull the
#                            registry fetches what the cache rule names from
#                            Microsoft Artifact Registry, outside the network,
#                            and serves it inside. Nothing in the network
#                            asks MCR.
#   docker.io/..., ...       what the run carries across the gap, copied in
#                            from the connected side by digest, under each
#                            image's original path (scripts/inside.sh).
#
# The connected side, the runner, reaches the registry from its own address
# only (/32): an IP rule, with everything else refused. Nothing is pushed from
# inside. The kubelet pulls as aks/bootstrap.sh's airgap-kubelet identity
# (AcrPull); no admin user, no anonymous pull. The run's delete takes the
# registry with what it holds.

resource "azurerm_container_registry" "inside" {
  name                          = replace(var.cluster_name, "-", "")
  resource_group_name           = azurerm_resource_group.this.name
  location                      = var.location
  sku                           = "Premium"
  admin_enabled                 = false
  anonymous_pull_enabled        = false
  data_endpoint_enabled         = true
  public_network_access_enabled = true
  tags                          = local.tags

  network_rule_set = [{
    default_action = "Deny"
    ip_rule        = [for c in var.operator_cidrs : { action = "Allow", ip_range = c }]
  }]
}

# The name and both paths are AKS's: a network isolated cluster with its own
# registry looks for exactly this rule.
resource "azapi_resource" "aks_cache" {
  type      = "Microsoft.ContainerRegistry/registries/cacheRules@2025-11-01"
  name      = "aks-managed-mcr"
  parent_id = azurerm_container_registry.inside.id
  body = {
    properties = {
      sourceRepository = "mcr.microsoft.com/*"
      targetRepository = "aks-managed-repository/*"
    }
  }
}

resource "azurerm_private_dns_zone" "registry" {
  name                = "privatelink.azurecr.io"
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "registry" {
  name                 = var.cluster_name
  private_dns_zone_id  = azurerm_private_dns_zone.registry.id
  virtual_network_id   = azurerm_virtual_network.this.id
  registration_enabled = false
  tags                 = local.tags
}

# The registry's REST endpoint and its data endpoint in the region, each an
# address in the registry's subnet, each written into the private zone.
resource "azurerm_private_endpoint" "registry" {
  name                = "${var.cluster_name}-registry"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  subnet_id           = azurerm_subnet.registry.id
  tags                = local.tags

  private_service_connection {
    name                           = "registry"
    private_connection_resource_id = azurerm_container_registry.inside.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "registry"
    private_dns_zone_ids = [azurerm_private_dns_zone.registry.id]
  }
}
