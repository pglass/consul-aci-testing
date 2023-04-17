set -eux

consul catalog services

CONTAINER_IP=$(nslookup -type=a ${dns_name_label} \
    | grep Address | tail -n1 | cut -d' ' -f 2)

cat <<EOF | tee services.json
${jsonencode({
  services = [
    {
      address = "$CONTAINER_IP"
      id = service.id
      name = service.name
      port = service.port
      checks = [
        {
          Name = "Service Listening (fake check)"
          TTL = "999999h"
          Status = "passing"
        }
      ]
    },
    {
      address = "$CONTAINER_IP"
      id = "${service.id}-sidecar-proxy"
      name = "${service.name}-sidecar-proxy"
      port = 20000
      kind = "connect-proxy"
      proxy = {
        destination_service_id = service.id
        destination_service_name = service.name
        local_service_address = "127.0.0.1"
        local_service_port = service.port
        upstreams = lookup(service, "upstreams", [])
        config = {
          bind_address = "0.0.0.0"
        }
      }
      checks = [
        {
          Name = "Connect Sidecar Listening (fake check)"
          TTL = "999999h"
          Status = "passing"
        }
      ]
    }
  ]
})}
EOF

consul services register services.json

consul catalog services
