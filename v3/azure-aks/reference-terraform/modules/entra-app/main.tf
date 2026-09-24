data "azuread_client_config" "current" {}

# Entra ID app registration used as the OIDC provider for user sign-in.
# The identity running Terraform must hold Microsoft Graph rights to create
# app registrations (Application.ReadWrite.OwnedBy, or the Application
# Administrator / Cloud Application Administrator role).
resource "azuread_application" "this" {
  display_name     = var.display_name
  sign_in_audience = "AzureADMyOrg"

  # Emit a `groups` claim with the user's security-group object IDs, which
  # the application can map to workspace roles.
  group_membership_claims = ["SecurityGroup"]

  # Force-include `email` in tokens. Entra sources it only from the user's
  # `mail` attribute; the application falls back to preferred_username / upn
  # for users without one, and refuses a sign-in with no usable address.
  optional_claims {
    id_token {
      name = "email"
    }
    access_token {
      name = "email"
    }
  }

  web {
    redirect_uris = var.redirect_uris
    logout_url    = var.logout_url

    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = false
    }
  }
}

resource "azuread_service_principal" "this" {
  client_id = azuread_application.this.client_id
}

resource "azuread_application_password" "this" {
  # No end_date: the azuread provider defaults to a two-year validity, and
  # the secret is not rotated automatically. To rotate it before expiry,
  # `terraform apply -replace='module.entra_app["<deployment>"].azuread_application_password.this'`
  # and upgrade the release with the re-rendered values file.
  application_id = azuread_application.this.id
  display_name   = "terraform-managed"
}
