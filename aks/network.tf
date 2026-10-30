# A network with no way out (ADR 23). On Azure a virtual network has no route
# to the internet of its own, but a VM in it was long given one anyway:
# default outbound access, an address Azure picks. Every subnet here turns it
# off, and the cluster's outbound type is none: AKS makes no load balancer
# rule, NAT gateway or route out either. No public address, NAT gateway, route
# table, firewall, peering or gateway is declared anywhere in this directory,
# and static check "aks" fails if one is.
#
# The network security group on the nodes' subnet says it again: egress to
# anything outside the network's own range and the pods' is denied. Two
# addresses no rule here governs are Azure's own and answer from the host the
# node runs on: 168.63.129.16, Azure's DNS (dns.tf closes it) and its health
# probes, and 169.254.169.254, the instance metadata service.
#
# Three subnets: the nodes; the API server's, delegated to AKS, which puts
# the control plane's private address there (API Server VNet Integration, so
# the nodes reach it inside the network); and the registry's private
# endpoint (registry.tf).

locals {
  nodes_cidr     = cidrsubnet(var.vpc_cidr, 4, 0)
  apiserver_cidr = cidrsubnet(var.vpc_cidr, 12, 256)
  registry_cidr  = cidrsubnet(var.vpc_cidr, 8, 17)
}

# One delete takes all of it: the run's resource group. AKS makes a second,
# for the node's VM, disk and network interface, named after this one, and
# deletes it with the cluster.
resource "azurerm_resource_group" "this" {
  name     = var.cluster_name
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "this" {
  name                = var.cluster_name
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  address_space       = [var.vpc_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "nodes" {
  name                            = "nodes"
  resource_group_name             = azurerm_resource_group.this.name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [local.nodes_cidr]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "apiserver" {
  name                            = "apiserver"
  resource_group_name             = azurerm_resource_group.this.name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [local.apiserver_cidr]
  default_outbound_access_enabled = false

  delegation {
    name = "aks"
    service_delegation {
      name = "Microsoft.ContainerService/managedClusters"
    }
  }
}

resource "azurerm_subnet" "registry" {
  name                              = "registry"
  resource_group_name               = azurerm_resource_group.this.name
  virtual_network_name              = azurerm_virtual_network.this.name
  address_prefixes                  = [local.registry_cidr]
  default_outbound_access_enabled   = false
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_network_security_group" "nodes" {
  name                = "${var.cluster_name}-nodes"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  tags                = local.tags

  security_rule {
    name                         = "egress-inside"
    description                  = "The nodes, the API server's address, the registry's endpoint, and the pods (ADR 23)."
    priority                     = 100
    direction                    = "Outbound"
    access                       = "Allow"
    protocol                     = "*"
    source_address_prefix        = "*"
    source_port_range            = "*"
    destination_address_prefixes = [var.vpc_cidr, var.pod_cidr]
    destination_port_range       = "*"
  }

  security_rule {
    name                       = "deny-egress"
    description                = "Nothing leaves the network but what the rule above this one allows (ADR 23)."
    priority                   = 4096
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_address_prefix      = "*"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "nodes" {
  subnet_id                 = azurerm_subnet.nodes.id
  network_security_group_id = azurerm_network_security_group.nodes.id
}
