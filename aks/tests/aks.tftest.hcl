# What the boundary on AKS promises (ADR 23), checked on a plan against mocked
# Azure providers: no subscription, no credentials, no cost. Run by static
# check "aks"; what no plan shows (a public address, a NAT gateway or a route
# table declared anywhere) the same check reads from the files, and
# tests/e2e/aks.sh tries on AKS.

# Computed values are known at plan, so a test can compare ids.
mock_provider "azurerm" {
  override_during = plan

  mock_data "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/airgap-identities/providers/Microsoft.ManagedIdentity/userAssignedIdentities/airgap-identity"
      client_id    = "11111111-1111-1111-1111-111111111111"
      principal_id = "22222222-2222-2222-2222-222222222222"
    }
  }
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/airgap-12345678901" }
  }
  mock_resource "azurerm_virtual_network" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/airgap-12345678901/providers/Microsoft.Network/virtualNetworks/airgap-12345678901" }
  }
  mock_resource "azurerm_container_registry" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/airgap-12345678901/providers/Microsoft.ContainerRegistry/registries/airgap12345678901"
      login_server = "airgap12345678901.azurecr.io"
    }
  }
}

mock_provider "azapi" {
  override_during = plan

  mock_resource "azapi_resource" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/airgap-12345678901/providers/Microsoft.Network/dnsResolverPolicies/airgap-12345678901" }
  }
}

# Each subnet its own id, so a test can tell which one a thing is in.
override_resource {
  target          = azurerm_subnet.nodes
  override_during = plan
  values          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/airgap-12345678901/providers/Microsoft.Network/virtualNetworks/airgap-12345678901/subnets/nodes" }
}

override_resource {
  target          = azurerm_subnet.apiserver
  override_during = plan
  values          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/airgap-12345678901/providers/Microsoft.Network/virtualNetworks/airgap-12345678901/subnets/apiserver" }
}

override_resource {
  target          = azurerm_subnet.registry
  override_during = plan
  values          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/airgap-12345678901/providers/Microsoft.Network/virtualNetworks/airgap-12345678901/subnets/registry" }
}

variables {
  run_id         = "12345678901"
  cluster_name   = "airgap-12345678901"
  operator_cidrs = ["203.0.113.7/32"]
}

run "no_way_out" {
  command = plan

  assert {
    condition     = !azurerm_subnet.nodes.default_outbound_access_enabled && !azurerm_subnet.apiserver.default_outbound_access_enabled && !azurerm_subnet.registry.default_outbound_access_enabled
    error_message = "no subnet gets Azure's default outbound access"
  }
  assert {
    condition     = one(azurerm_kubernetes_cluster.this.network_profile).outbound_type == "none"
    error_message = "the cluster's outbound type is none: AKS makes no way out"
  }
  assert {
    condition     = one(azurerm_kubernetes_cluster.this.default_node_pool).node_public_ip_enabled == false
    error_message = "the node has no public address"
  }
  assert {
    condition     = azurerm_subnet_network_security_group_association.nodes.subnet_id == azurerm_subnet.nodes.id
    error_message = "the network security group is on the nodes' subnet"
  }
}

run "the_firewall_says_it_again" {
  command = plan

  assert {
    condition     = length([for r in azurerm_network_security_group.nodes.security_rule : r if r.direction == "Outbound" && r.access == "Deny" && r.destination_address_prefix == "*" && r.protocol == "*"]) == 1
    error_message = "egress to anything is denied"
  }
  assert {
    condition     = alltrue([for r in azurerm_network_security_group.nodes.security_rule : toset(r.destination_address_prefixes) == toset(["10.42.0.0/16", "10.244.0.0/16"]) if r.direction == "Outbound" && r.access == "Allow"])
    error_message = "what is allowed out is the network's own range and the pods', nothing outside them"
  }
  assert {
    condition     = length([for r in azurerm_network_security_group.nodes.security_rule : r if r.direction == "Outbound" && r.access == "Allow"]) == 1
    error_message = "one egress rule allows, and it is the one above"
  }
}

run "no_name_lookup_out" {
  command = plan

  assert {
    condition     = toset(azapi_resource.refused.body.properties.domains) == toset(["."]) && azapi_resource.refuse.body.properties.action.actionType == "Block"
    error_message = "every name is refused"
  }
  assert {
    condition     = azapi_resource.allow.body.properties.priority < azapi_resource.refuse.body.properties.priority && azapi_resource.allow.body.properties.action.actionType == "Allow"
    error_message = "the names let through are let through before the refusal"
  }
  assert {
    condition     = toset(azapi_resource.allowed.body.properties.domains) == toset(["azurecr.io.", "internal.cloudapp.net."])
    error_message = "the names let through are the registry's and the network's own, nothing on the open internet"
  }
  assert {
    condition     = length(azapi_resource.dns_policy_link) == 1 && azapi_resource.dns_policy_link[0].body.properties.virtualNetwork.id == azurerm_virtual_network.this.id
    error_message = "the resolver policy is on the network by default"
  }
}

# The one run that shows the DNS check its violation.
run "dns_firewall_off_is_the_violation" {
  command = plan

  variables {
    dns_firewall = false
  }

  assert {
    condition     = length(azapi_resource.dns_policy_link) == 0
    error_message = "with dns_firewall off, the resolver policy is on no network"
  }
}

run "the_api_from_the_operator_only" {
  command = plan

  assert {
    condition     = toset(one(azurerm_kubernetes_cluster.this.api_server_access_profile).authorized_ip_ranges) == toset(["203.0.113.7/32"])
    error_message = "the API answers the operator's one address"
  }
  assert {
    condition     = one(azurerm_kubernetes_cluster.this.api_server_access_profile).virtual_network_integration_enabled && one(azurerm_kubernetes_cluster.this.api_server_access_profile).subnet_id == azurerm_subnet.apiserver.id
    error_message = "the node reaches the API server inside the network, in its delegated subnet"
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.run_command_enabled == false
    error_message = "no run command, a way in the authorized ranges do not cover"
  }
}

run "an_open_api_is_refused" {
  command = plan

  variables {
    operator_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.operator_cidrs]
}

run "a_name_the_sweep_would_miss_is_refused" {
  command = plan

  variables {
    cluster_name = "reference-platform-12345678901"
  }

  expect_failures = [var.cluster_name]
}

run "the_cluster_bootstraps_from_inside" {
  command = plan

  assert {
    condition     = one(azurerm_kubernetes_cluster.this.bootstrap_profile).artifact_source == "Cache" && one(azurerm_kubernetes_cluster.this.bootstrap_profile).container_registry_id == azurerm_container_registry.inside.id
    error_message = "AKS's own images and binaries come from the registry inside, not from mcr.microsoft.com"
  }
  assert {
    condition     = azapi_resource.aks_cache.name == "aks-managed-mcr" && azapi_resource.aks_cache.body.properties.targetRepository == "aks-managed-repository/*"
    error_message = "the cache rule is the one AKS looks for"
  }
  assert {
    condition     = one(azurerm_kubernetes_cluster.this.default_node_pool).node_count == 1 && azurerm_kubernetes_cluster.this.node_os_upgrade_channel == "None"
    error_message = "one node, and nothing upgrades under a run"
  }
}

run "network_policies_are_enforced" {
  command = plan

  assert {
    condition     = one(azurerm_kubernetes_cluster.this.network_profile).network_data_plane == "cilium" && one(azurerm_kubernetes_cluster.this.network_profile).network_policy == "cilium"
    error_message = "Cilium enforces NetworkPolicies; without it the agent's would be accepted and enforce nothing"
  }
}

run "the_registry_inside" {
  command = plan

  assert {
    condition     = azurerm_container_registry.inside.sku == "Premium" && !azurerm_container_registry.inside.admin_enabled && !azurerm_container_registry.inside.anonymous_pull_enabled
    error_message = "the run's own registry, with no admin user and no anonymous pull"
  }
  assert {
    condition     = one(azurerm_container_registry.inside.network_rule_set).default_action == "Deny" && toset([for r in one(azurerm_container_registry.inside.network_rule_set).ip_rule : r.ip_range]) == toset(["203.0.113.7/32"])
    error_message = "from outside the network, the registry answers the operator's one address"
  }
  assert {
    condition     = one(azurerm_private_endpoint.registry.private_service_connection).subresource_names == tolist(["registry"]) && azurerm_private_endpoint.registry.subnet_id == azurerm_subnet.registry.id
    error_message = "inside, the node reaches it through a private endpoint in the network"
  }
  assert {
    condition     = azurerm_private_dns_zone.registry.name == "privatelink.azurecr.io" && azurerm_private_dns_zone_virtual_network_link.registry.virtual_network_id == azurerm_virtual_network.this.id
    error_message = "and resolves its names in the network's own private zone"
  }
}
