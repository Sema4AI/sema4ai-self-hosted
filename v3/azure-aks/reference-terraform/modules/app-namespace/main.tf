# The namespace and service account for one deployment.
#
# The chart is pointed at the account with serviceAccount.create=false and
# serviceAccount.name=<this account>. On Azure the binding to the managed
# identity is a pair: the `azure.workload.identity/client-id` annotation set
# through var.service_account_annotations, and a federated identity credential
# on the identity naming this exact namespace and account (deployments.tf).
# The AKS webhook injects the token only into Pods labelled
# `azure.workload.identity/use: "true"`, which the chart does for its VFS Pods
# on infrastructure.platform=azure.

terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name   = var.namespace
    labels = var.labels
  }
}

resource "kubernetes_service_account_v1" "this" {
  metadata {
    name        = var.service_account
    namespace   = kubernetes_namespace_v1.this.metadata[0].name
    labels      = var.labels
    annotations = var.service_account_annotations
  }
}
