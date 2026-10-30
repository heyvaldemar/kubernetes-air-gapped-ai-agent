# AKS in the closed network (ADR 23): a network isolated cluster. Its
# outbound type is none, so AKS makes no way out, and its bootstrap artifact
# source is Cache: the node starts from the registry inside, which fetches
# AKS's own images and binaries through the cache rule, not from
# mcr.microsoft.com (registry.tf).
#
# The API server is projected into the network (API Server VNet Integration):
# the node reaches it at a private address in the delegated subnet, without
# DNS; the operator, the runner, reaches its public endpoint from its own
# address only (/32). No run command: `az aks command invoke` would be a way
# in that the authorized ranges do not cover.
#
# Azure CNI in overlay mode with Cilium's dataplane enforces the agent's
# NetworkPolicies, as kindnet does on kind, the VPC CNI on EKS and Dataplane
# V2 on GKE: without it they would be accepted and enforce nothing. No
# monitoring add-on, no Azure Policy, no Defender: each would need a way out.
#
# The control plane and the kubelet run as aks/bootstrap.sh's standing
# identities, whose roles the run's creation identity could not grant.

data "azurerm_user_assigned_identity" "cluster" {
  name                = "airgap-cluster"
  resource_group_name = var.identity_resource_group
}

data "azurerm_user_assigned_identity" "kubelet" {
  name                = "airgap-kubelet"
  resource_group_name = var.identity_resource_group
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  dns_prefix          = var.cluster_name
  node_resource_group = "${var.cluster_name}-nodes"
  kubernetes_version  = var.kubernetes_version
  sku_tier            = "Free"
  tags                = local.tags

  # A run lasts under an hour; nothing upgrades under it.
  node_os_upgrade_channel = "None"
  run_command_enabled     = false

  identity {
    type         = "UserAssigned"
    identity_ids = [data.azurerm_user_assigned_identity.cluster.id]
  }

  kubelet_identity {
    client_id                 = data.azurerm_user_assigned_identity.kubelet.client_id
    object_id                 = data.azurerm_user_assigned_identity.kubelet.principal_id
    user_assigned_identity_id = data.azurerm_user_assigned_identity.kubelet.id
  }

  # The one node pool below and no other: no node auto-provisioning, which
  # would add nodes the trial's four vCPUs cannot hold.
  node_provisioning_profile {
    mode = "Manual"
  }

  bootstrap_profile {
    artifact_source       = "Cache"
    container_registry_id = azurerm_container_registry.inside.id
  }

  api_server_access_profile {
    authorized_ip_ranges                = var.operator_cidrs
    subnet_id                           = azurerm_subnet.apiserver.id
    virtual_network_integration_enabled = true
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    outbound_type       = "none"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = cidrhost(var.service_cidr, 10)
  }

  default_node_pool {
    name                    = "nodes"
    node_count              = 1
    vm_size                 = var.node_vm_size
    vnet_subnet_id          = azurerm_subnet.nodes.id
    os_sku                  = "Ubuntu"
    os_disk_type            = "Managed"
    os_disk_size_gb         = 64
    node_public_ip_enabled  = false
    host_encryption_enabled = false
    tags                    = local.tags
  }

  depends_on = [
    azurerm_subnet_network_security_group_association.nodes,
    azurerm_private_endpoint.registry,
    azurerm_private_dns_zone_virtual_network_link.registry,
    azapi_resource.aks_cache,
    azapi_resource.dns_policy_link,
  ]
}
