# ---------------------------------------------------------------------------
# The sandbox runtime: Kata Containers, once per cluster, shared by every
# deployment.
#
# Agent code runs in a Kata microVM per run, which needs /dev/kvm on the node.
# The Kata chart installs onto a node without it and reports success, so this
# apply proves nothing about the node: only an agent run does (README.md,
# step 3).
#
# Installed exactly as the deployment guide installs it
# (https://sema4.ai/docs/v3/deploy/sandbox-runtime): the same release name,
# namespace, chart, version and values. A change to the values or the chart
# version is a helm upgrade that restarts containerd on the node, so apply it
# in a maintenance window. New Kata configuration applies to sandbox VMs
# created after it.
# ---------------------------------------------------------------------------

resource "helm_release" "kata_deploy" {
  name       = "kata-deploy"
  repository = "oci://ghcr.io/kata-containers/kata-deploy-charts"
  chart      = "kata-deploy"
  version    = "4.1.0" # the version the deployment guide installs; move it with the guide
  namespace  = "kube-system"

  # The published reference configuration, shared with every other target.
  values = [file("${path.module}/../../kata-containers/kata-values.yaml")]

  # `--wait --timeout 25m`, as the guide installs it: the node unpacks Kata
  # and restarts containerd before the DaemonSet reports ready.
  wait    = true
  timeout = 1500

  depends_on = [module.aks]
}
