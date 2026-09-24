# ---------------------------------------------------------------------------
# The cluster's one Gateway: the single origin behind every Front Door
# endpoint, shared by every deployment.
#
# It uses the approuting-istio GatewayClass, the application routing add-on's
# Gateway API implementation, which modules/aks turns on. Creating the Gateway
# is what makes the add-on stand up its data plane: a Deployment, a
# HorizontalPodAutoscaler (two replicas minimum), a PodDisruptionBudget and a
# public LoadBalancer Service, all named <gateway>-approuting-istio, in the
# Gateway's namespace. That Service's public IP is the Front Door origin
# (front-door.tf).
#
# One HTTP listener on port 80 and nothing else. TLS terminates at Front Door,
# which reaches this listener over plain HTTP, so the Gateway holds no
# certificate. It has no hostname either: each deployment's release renders
# an HTTPRoute (httpRoute in its values file) that claims the deployment's own
# Front Door hostname, which Front Door passes through as the Host header.
# Routes attach only from namespaces labelled app.kubernetes.io/part-of=sema4ai,
# which every deployment namespace carries (deployments.tf).
#
# kubernetes_manifest reads the cluster and the Gateway API CRDs at plan time,
# which is why a new cluster is applied with -target=module.aks first
# (README.md, step 1).
# ---------------------------------------------------------------------------

locals {
  gateway_namespace = "sema4ai-gateway"
  gateway_name      = "front-door"
  # The namespace/name of the Service the add-on generates for the Gateway,
  # which is how AKS tags the Service's public IP (front-door.tf).
  gateway_service = "${local.gateway_namespace}/${local.gateway_name}-approuting-istio"
}

resource "kubernetes_namespace_v1" "gateway" {
  metadata {
    name = local.gateway_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [module.aks]
}

resource "kubernetes_manifest" "gateway" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = local.gateway_name
      namespace = kubernetes_namespace_v1.gateway.metadata[0].name
    }
    spec = {
      gatewayClassName = "approuting-istio"
      listeners = [{
        name     = "http"
        port     = 80
        protocol = "HTTP"
        allowedRoutes = {
          namespaces = {
            from = "Selector"
            selector = {
              matchLabels = {
                "app.kubernetes.io/part-of" = "sema4ai"
              }
            }
          }
        }
      }]
    }
  }
}
