Overview
--------

This is a quick first attempt at running Consul service mesh in Azure Container Instances.

* All containers use public ips
* It uses a Consul dev server that runs in a container
* ACLs and TLS are not enabled on the Consul server

It runs two applications in the service mesh: `static-client` which talks to its upstream `static-server`

Each service mesh app runs in a container group that includes:

* An init container to register the service instance + sidecar into Consul at container startup
* A consul-dataplane sidecar container to connect to Consul and run Envoy

Challenges
----------

### Container IP Discovery

This approach requires that a container is able to discover its own ip address, in order to include
its IP in the service registration to Consul during start up.

I couldn't find a good way for the container to find its own IP address. Some places I tried:

* Environment variables:
  * There wasn't a simple environment variable in the container with the container IP.
  * There are [environment variables related to Service Fabric](
    https://learn.microsoft.com/en-us/azure/service-fabric/service-fabric-environment-variables-reference)
    which do contain an IP and other info. I couldn't make sense of these. They didn't directly
    provide any container information, anD didn't lead me to the (public) container ip. But this
    might be worth exploring further.
* Metadata Service: There is a [metadata
  service](https://learn.microsoft.com/en-us/azure/container-instances/container-instances-managed-identity#use-user-assigned-identity-to-get-secret-from-key-vault), but I couldn't find the container IP there.
* DNS: With this setup, each container had a public IP and a DNS name.
  The container can do a DNS query to find the public IP. This worked, but
  because the DNS name is reused when the container is cycled, this
  approach could potentially retrieve an old IP address. (We would
  need some way to check we have the correct IP after the DNS lookup,
  and retry until we get the right IP, maybe?)
* Azure API: We could have the container make a request to the Azure API when it starts up. It could
  fetch the container group to find the ip address there. I was able to start a container with an
  identity assigned, however in my test account I didn't have permission to assign roles/permissions
  so I wasn't able to validate this.

  I've seen some documentation state that managed identities are unavailable in ACI when using
  virtual networks. [This
  post](https://techcommunity.microsoft.com/t5/azure-compute-blog/new-regions-and-managed-identity-support-for-azure-container/ba-p/3645269)
  seems to state otherwise.


### Service Deregistration

We need service instances to be deregistered when a container stops.
This needs a bit of exploration:

* The container can intercept the TERM signal, and deregister itself from Consul.
  However, this could potentially fail.
* Instead, we likely need a separate "controller" that monitors for stopped containers
  and ensures they are eventually deregistered.
* We could switch to running consul client agents. Client agents leave the Consul cluster
  on sigterm, which removes the services on that node from Consul. And because Consul agents
  gossip, if the leave fails, then the node is marked unhealthy and removed (eventually, after
  72hr). Consul client agents also provide health checks.


### ACL Tokens

Consul does not have an auth method for Azure, so we need some other way to provide an ACL
token to a container. Probably, a controller-based approach similar to Consul on ECS is
necessary or some other external process for managing service tokens for containers.
We also need to cleanup tokens for stopped containers, which would necessaitate
an external process to reconcile running tasks with tokens in Consul and remove
tokens that are no longer used by ACI.

### Health Checks

Consul Dataplane does not provide health checking. I didn't explore this, but initial thoughts:

* ACI supports readiness and liveness probes
* An additional sidecar container could sync liveness probes into Consul
  This would require that container to be able to find the result of the liveness probe.
  From what I've seen so far, that information isn't immediately avaialble to the container,
  so it might require an Azure API request.
* Or, an external process could sync readiness probes into Consul
* Or, we could switch to using Consul clients, and users could define Consul native health
  checks for the client agent to run.
