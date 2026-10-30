output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "resource_group" {
  description = "The run's resource group: one delete takes everything the run made."
  value       = azurerm_resource_group.this.name
}

output "node_resource_group" {
  description = "The group AKS makes for the node, and deletes with the cluster."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "registry" {
  description = "The registry inside: this run's registry's login server."
  value       = azurerm_container_registry.inside.login_server
}

output "inside" {
  description = "The registry inside for scripts/inside.sh: every image goes under its original path here."
  value       = azurerm_container_registry.inside.login_server
}

output "registry_name" {
  value = azurerm_container_registry.inside.name
}

output "registry_cidr" {
  description = "The private endpoint's subnet: inside the network, the registry's names resolve to addresses here."
  value       = local.registry_cidr
}

output "dns_firewall" {
  value = var.dns_firewall
}
