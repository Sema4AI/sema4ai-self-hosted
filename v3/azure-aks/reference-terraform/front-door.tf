# ---------------------------------------------------------------------------
# Front Door — the public hostname of every deployment.
#
# There is no custom domain, no DNS record to create and no certificate in
# the cluster. Each deployment is reached at an Azure-generated Front Door
# endpoint hostname (<endpoint>-<hash>.z01.azurefd.net) whose TLS certificate
# Microsoft issues, serves and rotates. The hostnames are only known after an
# apply, so everything downstream that needs one — the HTTPRoute hostname, the
# values file's applicationUrl, the Entra ID redirect URI — reads it back off
# these resources rather than off a variable.
#
# The hop from the Front Door edge to the cluster is plain HTTP. The Gateway
# has no certificate a public CA would sign, and Front Door rejects an origin
# whose certificate does not chain to a trusted root. The origin is therefore
# restricted to Front Door by the network security group below. If an
# unencrypted edge-to-origin hop is not acceptable, the answer is the Premium
# SKU with Private Link to an internal load balancer, or TLS at the Gateway on
# a hostname of your own; see README.md.
# ---------------------------------------------------------------------------

resource "azurerm_cdn_frontdoor_profile" "this" {
  name                = "afd-${var.infra_id}"
  resource_group_name = azurerm_resource_group.this.name
  sku_name            = "Standard_AzureFrontDoor"

  # The ceiling on a single origin response; 240s is the maximum Front Door
  # accepts. The Gateway sets no request timeout of its own, so past four
  # minutes on one non-WebSocket response the edge returns 504. WebSocket
  # connections are governed by Front Door's own limits instead.
  response_timeout_seconds = 240
}

# The Gateway's public IP: the one AKS allocates in the node resource group
# for the Service the add-on generates for the Gateway (gateway.tf), and tags
# with that Service's namespace and name (k8s-azure-service). The tag, not the
# name, singles it out: AKS names every Service IP after a hash of the
# Service's UID, with the same kubernetes- prefix.
#
# The IP does not exist until the Gateway is programmed, a minute or so after
# the apply that creates it, so the origin, the routes and the network
# security group below are created on the first apply that finds it
# (README.md, step 1).
#
# The lookup must be answerable at plan time, because it decides how many of
# those resources there are. So it is a subscription-wide query with constant
# arguments, matched against the node resource group by name (which the aks
# module sets explicitly for exactly this reason), rather than a query scoped
# to the node resource group: that group does not exist on a first plan, and
# a reference to the cluster's attributes would be unknown until apply.
data "azurerm_resources" "public_ips" {
  type = "Microsoft.Network/publicIPAddresses"
}

locals {
  node_public_ips = [
    for r in data.azurerm_resources.public_ips.resources : r
    if lower(r.resource_group_name) == lower(local.node_resource_group)
  ]
  ingress_ip_names = [
    for r in local.node_public_ips : r.name
    if lookup(coalesce(r.tags, {}), "k8s-azure-service", "") == local.gateway_service
  ]
}

data "azurerm_public_ip" "ingress" {
  count = length(local.ingress_ip_names) > 0 ? 1 : 0

  name                = local.ingress_ip_names[0]
  resource_group_name = local.node_resource_group
}

locals {
  ingress_public_ip = one(data.azurerm_public_ip.ingress[*].ip_address)
}

resource "azurerm_cdn_frontdoor_origin_group" "ingress" {
  name                     = "ingress"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id

  load_balancing {}

  # No health_probe block, deliberately. A probe arrives at the origin with
  # the origin's own IP as its Host, matches no HTTPRoute hostname, and the
  # Gateway answers it 404, which would take the only origin out of rotation
  # and fail every request. Front Door allows probing to be
  # off only for a single origin in a single origin group, which is exactly
  # this shape.
}

resource "azurerm_cdn_frontdoor_origin" "ingress" {
  count = local.ingress_public_ip == null ? 0 : 1

  name                          = "ingress"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.ingress.id
  host_name                     = local.ingress_public_ip

  # Explicit, despite the documented default of true: left unset, the origin
  # is created disabled, and every route into this group then fails to create
  # with "at least one enabled origin is created under the origin group". The
  # routes below set it for the same reason.
  enabled = true

  # origin_host_header is left unset on purpose: Front Door then forwards the
  # Host it received, which is the endpoint hostname the browser asked for.
  # That is what lets one origin serve every endpoint below: the Gateway
  # matches each request to whichever deployment's HTTPRoute declares that
  # host.
  #
  # Only reached over HTTP, so the certificate check has nothing to check.
  certificate_name_check_enabled = false
}

# One endpoint per deployment. Each gets its own hostname and its own managed
# certificate; they share the one origin, and are told apart at the Gateway by
# the Host header Front Door passes through.
resource "azurerm_cdn_frontdoor_endpoint" "deployment" {
  # Keyed off the input variable rather than local.deployments, which reads
  # host_name back off these endpoints; going through the local would be a
  # cycle.
  for_each = var.deployment_ids

  name                     = each.key
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id
}

# Routes are created with the origin, not with the endpoints: Front Door
# rejects a route whose origin group holds no origins, so on the first apply
# of a new cluster there is nothing to route to yet. The endpoints still come
# up, which is what matters: their hostnames are what the values files and the
# Entra ID app registrations are built from.
resource "azurerm_cdn_frontdoor_route" "deployment" {
  for_each = local.ingress_public_ip == null ? {} : azurerm_cdn_frontdoor_endpoint.deployment

  name                          = "default"
  cdn_frontdoor_endpoint_id     = each.value.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.ingress.id
  cdn_frontdoor_origin_ids      = azurerm_cdn_frontdoor_origin.ingress[*].id

  enabled                = true
  patterns_to_match      = ["/*"]
  supported_protocols    = ["Http", "Https"]
  forwarding_protocol    = "HttpOnly"
  https_redirect_enabled = true
  link_to_default_domain = true
}

# ---------------------------------------------------------------------------
# Keep the origin private to Front Door.
#
# The node subnet has no network security group by default, which leaves the
# Gateway's load balancer answering anyone who finds the IP, over HTTP, with
# none of the edge's TLS. This admits the AzureFrontDoor.Backend service tag
# on port 80 and nothing else from the internet; Azure's default rules still
# allow the virtual network and the load balancer's health probes, and egress
# is untouched.
#
# The tag covers every Front Door in Azure, not only this profile. Pinning it
# to this profile means rejecting requests whose X-Azure-FDID header is not
# this profile's ID (its resource_guid) at the Gateway; see README.md.
#
# The destination is the load balancer's public IP, not VirtualNetwork. AKS
# gives a Service's load balancing rules floating IP (Direct Server Return)
# unless the Service opts out, so the packet arrives at the node still
# addressed to the frontend IP: a VirtualNetwork destination never matches
# it, and the default DenyAllInBound then drops every request as a Front Door
# 504. The Gateway's Service also exposes Istio's status port (15021); nothing
# here admits it from outside.
# ---------------------------------------------------------------------------

resource "azurerm_network_security_group" "ingress" {
  # Named for a destination that does not exist until the Gateway does.
  count = local.ingress_public_ip == null ? 0 : 1

  name                = "nsg-${var.infra_id}-ingress"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  security_rule {
    name                       = "AllowFrontDoorInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "AzureFrontDoor.Backend"
    destination_address_prefix = local.ingress_public_ip
  }
}

resource "azurerm_subnet_network_security_group_association" "ingress" {
  count = local.ingress_public_ip == null ? 0 : 1

  subnet_id                 = module.networking.aks_subnet_id
  network_security_group_id = azurerm_network_security_group.ingress[0].id
}
