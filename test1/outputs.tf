output "consul_http_addr" {
  value = "http://${azurerm_container_group.consul-server.fqdn}:8500"
}

output "static_client_addr" {
  value = "http://${azurerm_container_group.static-client.fqdn}:9090"
}
