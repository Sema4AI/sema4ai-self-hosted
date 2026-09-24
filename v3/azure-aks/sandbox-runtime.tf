# ---------------------------------------------------------------------------
# The sandbox runtime: Kata Containers, once per cluster, shared by every
# deployment.
#
# Agent code runs in a Kata microVM per run, which needs /dev/kvm on the node.
# The Kata chart installs onto a node without it and reports success, and so
# does the application, so the node is checked first and the install waits
# for the check to pass.
#
# Installed exactly as the deployment guide installs it
# (https://sema4.ai/docs/v3/deploy/sandbox-runtime): the same release name,
# namespace, chart, version and values. A change to the values or the chart
# version is a helm upgrade that restarts containerd on the node, so apply it
# in a maintenance window. New Kata configuration applies to sandbox VMs
# created after it.
# ---------------------------------------------------------------------------

locals {
  # The version the deployment guide installs; move it with the guide.
  kata_deploy_chart_version = "4.1.0"

  # The node check, from the manifest the deployment guide gives for running
  # it by hand, so the two cannot drift apart.
  kvm_check = yamldecode(file("${path.module}/k8s/kvm-check.yaml"))
}

# Replaced with the node's VM size, which is what decides whether the node
# exposes /dev/kvm, so the check runs again on the new node.
resource "terraform_data" "node_vm_size" {
  input = var.node_vm_size
}

resource "kubernetes_job_v1" "kvm_check" {
  metadata {
    name      = local.kvm_check.metadata.name
    namespace = local.kvm_check.metadata.namespace
  }

  spec {
    backoff_limit = 0

    template {
      metadata {}
      spec {
        restart_policy = "Never"
        node_selector  = local.kvm_check.spec.template.spec.nodeSelector

        container {
          name    = "check"
          image   = local.kvm_check.spec.template.spec.containers[0].image
          command = local.kvm_check.spec.template.spec.containers[0].command

          env {
            name = "NODE_NAME"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }

          volume_mount {
            name       = "host-dev"
            mount_path = "/host-dev"
            read_only  = true
          }
          volume_mount {
            name       = "host-run-containerd"
            mount_path = "/host-run/containerd"
            read_only  = true
          }
        }

        volume {
          name = "host-dev"
          host_path {
            path = "/dev"
            type = "Directory"
          }
        }
        volume {
          name = "host-run-containerd"
          host_path {
            path = "/run/containerd"
            type = "Directory"
          }
        }
      }
    }
  }

  # A failed check fails the apply here, before Kata is installed. Read why
  # with `kubectl -n default logs job/kvm-check` (README.md, step 1).
  wait_for_completion = true
  timeouts {
    create = "5m"
    update = "5m"
  }

  lifecycle {
    replace_triggered_by = [terraform_data.node_vm_size]
  }

  depends_on = [module.aks]
}

resource "helm_release" "kata_deploy" {
  name       = "kata-deploy"
  repository = "oci://ghcr.io/kata-containers/kata-deploy-charts"
  chart      = "kata-deploy"
  version    = local.kata_deploy_chart_version
  namespace  = "kube-system"

  # The published reference configuration, shared with every other target.
  values = [file("${path.module}/../kata-containers/kata-values.yaml")]

  # `--wait --timeout 25m`, as the guide installs it: the node unpacks Kata
  # and restarts containerd before the DaemonSet reports ready.
  wait    = true
  timeout = 1500

  depends_on = [kubernetes_job_v1.kvm_check]
}
