# ---------------------------------------------------------------------------
# Each deployment's database and roles, on the shared Flexible Server.
#
# The application does not create its database, and it connects with three
# least-privilege roles rather than the server administrator. The server has
# no public endpoint, so Terraform cannot reach it from where it runs; a Job
# in the cluster runs the SQL in templates/database.sql.tftpl as the
# administrator instead, and the apply waits for it.
#
# The Jobs and their Secrets live in a namespace of their own, because each
# Secret holds the administrator password. The SQL is idempotent, and a Job
# runs again whenever its Secret changes.
#
# Removing a deployment from var.deployment_ids deletes its Job and Secret,
# not its database or roles (README.md, Cleanup).
# ---------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "database_setup" {
  metadata {
    name = "sema4ai-database-setup"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [module.aks]
}

resource "kubernetes_secret_v1" "database_setup" {
  for_each = local.deployments

  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.database_setup.metadata[0].name
  }

  data = {
    PGPASSWORD = module.postgres.admin_password
    "setup.sql" = templatefile("${path.module}/templates/database.sql.tftpl", {
      deployment_id     = each.key
      database          = each.value.database
      app_role          = local.database_roles[each.key].app
      app_password      = random_password.app_role[each.key].result
      definer_role      = local.database_roles[each.key].definer
      migrator_role     = local.database_roles[each.key].migrator
      migrator_password = random_password.migrator_role[each.key].result
    })
  }
}

resource "kubernetes_job_v1" "database_setup" {
  for_each = local.deployments

  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.database_setup.metadata[0].name
  }

  spec {
    # Retries ride out a server that is still coming up, or a Pod caught by
    # containerd restarting on the node.
    backoff_limit = 4

    template {
      metadata {}
      spec {
        restart_policy = "Never"

        container {
          name    = "psql"
          image   = "postgres:17-alpine"
          command = ["psql", "--no-psqlrc", "--set=ON_ERROR_STOP=1", "--file=/setup/setup.sql"]

          env {
            name  = "PGHOST"
            value = module.postgres.host
          }
          env {
            name  = "PGUSER"
            value = module.postgres.admin_username
          }
          env {
            name  = "PGDATABASE"
            value = "postgres"
          }
          env {
            name  = "PGSSLMODE"
            value = "require"
          }
          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.database_setup[each.key].metadata[0].name
                key  = "PGPASSWORD"
              }
            }
          }

          volume_mount {
            name       = "setup"
            mount_path = "/setup"
            read_only  = true
          }
        }

        volume {
          name = "setup"
          secret {
            secret_name = kubernetes_secret_v1.database_setup[each.key].metadata[0].name
            items {
              key  = "setup.sql"
              path = "setup.sql"
            }
          }
        }
      }
    }
  }

  # A failure fails the apply. Read why with
  # `kubectl -n sema4ai-database-setup logs job/<deployment>`.
  wait_for_completion = true
  timeouts {
    create = "10m"
    update = "10m"
  }

  lifecycle {
    replace_triggered_by = [kubernetes_secret_v1.database_setup[each.key]]
  }

  # The server's extension allow-list, which the application's first
  # migration needs; and Kata, whose install restarts containerd under
  # running Pods.
  depends_on = [
    module.postgres,
    helm_release.kata_deploy,
  ]
}
