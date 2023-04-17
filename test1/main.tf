resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_resource_group" "example" {
  name     = "consul-test1"
  location = "Central US"
}

# Consul dev server for testing.
resource "azurerm_container_group" "consul-server" {
  name                = "consul-server-${random_string.suffix.result}"
  location            = azurerm_resource_group.example.location
  resource_group_name = azurerm_resource_group.example.name
  ip_address_type     = "Public"
  dns_name_label      = "consul-server-${random_string.suffix.result}"
  os_type             = "Linux"

  # Expose the HTTP UI/API for debugging
  exposed_port {
    port     = 8500
    protocol = "TCP"
  }
  # Expose the GRPC endpoint for consul-dataplane.
  exposed_port {
    port     = 8502
    protocol = "TCP"
  }

  container {
    name   = "consul-server"
    image  = "hashicorp/consul:1.15.2"
    cpu    = "0.5"
    memory = "0.5"

    commands = [
      "consul", "agent", "-dev",
      "-client", "0.0.0.0",
      "-node", "aci-centralus",
    ]

    ports {
      port     = 8500
      protocol = "TCP"
    }

    ports {
      port     = 8502
      protocol = "TCP"
    }
  }
}

# Example "server" app
resource "azurerm_container_group" "static-server" {
  name                = "static-server-${random_string.suffix.result}"
  location            = azurerm_resource_group.example.location
  resource_group_name = azurerm_resource_group.example.name
  ip_address_type     = "Public" // TODO: private ip
  dns_name_label      = "static-server-${random_string.suffix.result}"
  os_type             = "Linux"

  # Expose Envoy's public listener port.
  exposed_port {
    port     = 20000
    protocol = "TCP"
  }

  # Not necessary. I was trying to have the container use the Azure API
  # to find its ip address. However, from what I can tell this wouldn't
  # work with containers in a virtual network because managed identities
  # are not supported. I also couldn't assign roles in my test account
  # so was unable to test this.
  identity {
    type = "SystemAssigned"
  }

  container {
    name   = "static-server"
    image  = "nicholasjackson/fake-service:v0.24.2"
    cpu    = "0.5"
    memory = "0.5"

    environment_variables = {
      LISTEN_ADDR = "127.0.0.1:9090"
    }

    # I'm not sure if this is needed. Do I need to expose a port
    # for other containers in the same group to access this service?
    # If so, then this is needed for envoy to proxy requests through
    # to this app.
    ports {
      port     = 9090
      protocol = "TCP"
    }

  }

  # Consul Dataplane sidecar container. This connects to the consul server and starts envoy.
  container {
    name   = "consul-dataplane"
    image  = "hashicorp/consul-dataplane:1.1.0"
    cpu    = "0.5"
    memory = "0.5"

    # Expose the Envoy listener port. We expose this outside the container.
    ports {
      port     = 20000
      protocol = "TCP"
    }

    environment_variables = {
      # Consul Server GRPC Adddress. This can be a script and the go-discover binary
      # is included in the consul-dataplane image for cloud auto-join style server discovery.
      # https://developer.hashicorp.com/consul/docs/connect/dataplane/consul-dataplane#command-options
      DP_CONSUL_ADDRESSES      = azurerm_container_group.consul-server.fqdn
      DP_CONSUL_GRPC_PORT      = "8502"
      DP_LOG_LEVEL             = "DEBUG"
      DP_PROXY_SERVICE_ID      = "static-server-1-sidecar-proxy"
      DP_SERVICE_NODE_NAME     = "aci-centralus"
      DP_TLS_DISABLED          = "true"
      DP_SERVER_WATCH_DISABLED = "true" # Because the Consul server thinks it's at 127.0.0.1:8502
    }
  }

  # Use an init container to register the service + sidecar with Consul.
  init_container {
    name  = "mesh-init"
    image = "hashicorp/consul:1.15.2"

    commands = [
      "/bin/sh",
      "-c",
      templatefile("init-service.sh", {
        # TODO: This was seemingly the only way I could find for the container to discover its own ip address.
        # In this approach it needs to know its address in order to register into Consul.
        #
        # We pass the DNS name that will be assigned to the container, which we can predict.
        # The container starts and does a DNS query to find its IP.
        # This actually seemed to work when the container, but requires the container to use public ips.
        dns_name_label = "static-server-${random_string.suffix.result}.${azurerm_resource_group.example.location}.azurecontainer.io"
        service = {
          name = "static-server",
          id   = "static-server-1",
          port = 9090
        }
      })
    ]

    environment_variables = {
      CONSUL_HTTP_ADDR = "http://${azurerm_container_group.consul-server.fqdn}:8500"
    }
  }

}

# This is the example "client" app that talks to the server.
resource "azurerm_container_group" "static-client" {
  name                = "static-client-${random_string.suffix.result}"
  location            = azurerm_resource_group.example.location
  resource_group_name = azurerm_resource_group.example.name
  ip_address_type     = "Public" // TODO: private ip
  dns_name_label      = "static-client-${random_string.suffix.result}"
  os_type             = "Linux"

  # This is the app's listener port. This is only exposed for testing/debugging.
  exposed_port {
    port     = 9090
    protocol = "TCP"
  }

  # Envoy's public listener port.
  exposed_port {
    port     = 20000
    protocol = "TCP"
  }

  container {
    name   = "static-client"
    image  = "nicholasjackson/fake-service:v0.24.2"
    cpu    = "0.5"
    memory = "0.5"

    // https://hub.docker.com/r/nicholasjackson/fake-service
    environment_variables = {
      LISTEN_ADDR = "0.0.0.0:9090"
      # 9091 is the local Envoy listener for the "static-server" upstream
      UPSTREAM_URIS = "http://localhost:9091"
    }

    ports {
      port     = 9090
      protocol = "TCP"
    }
  }

  container {
    name   = "consul-dataplane"
    image  = "hashicorp/consul-dataplane:1.1.0"
    cpu    = "0.5"
    memory = "0.5"

    ports {
      port     = 20000
      protocol = "TCP"
    }

    environment_variables = {
      # Consul Server GRPC Adddress. This can be a script and the go-discover binary
      # is included in the consul-dataplane image.
      # https://developer.hashicorp.com/consul/docs/connect/dataplane/consul-dataplane#command-options
      DP_CONSUL_ADDRESSES      = azurerm_container_group.consul-server.fqdn
      DP_CONSUL_GRPC_PORT      = "8502"
      DP_LOG_LEVEL             = "DEBUG"
      DP_PROXY_SERVICE_ID      = "static-client-1-sidecar-proxy"
      DP_SERVICE_NODE_NAME     = "aci-centralus"
      DP_TLS_DISABLED          = "true"
      DP_SERVER_WATCH_DISABLED = "true" # Because the Consul server thinks it's at 127.0.0.1:8502
    }
  }

  init_container {
    name  = "mesh-init"
    image = "hashicorp/consul:1.15.2"

    commands = [
      "/bin/sh",
      "-c",
      templatefile("init-service.sh", {
        dns_name_label = "static-client-${random_string.suffix.result}.${azurerm_resource_group.example.location}.azurecontainer.io"
        service = {
          name = "static-client",
          id   = "static-client-1",
          port = 9090
          upstreams = [
            {
              destination_name = "static-server",
              local_bind_port  = 9091
            }
          ]
        }
      })
    ]

    environment_variables = {
      CONSUL_HTTP_ADDR = "http://${azurerm_container_group.consul-server.fqdn}:8500"
    }
  }
}
