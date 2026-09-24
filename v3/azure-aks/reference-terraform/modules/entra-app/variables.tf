variable "display_name" {
  type        = string
  description = "Display name of the Entra ID app registration."
}

variable "redirect_uris" {
  type        = list(string)
  description = "OIDC redirect URIs registered on the app: https://<hostname>/api/v1/auth/callback."
  validation {
    condition     = length(var.redirect_uris) > 0
    error_message = "At least one redirect URI is required."
  }
}

variable "logout_url" {
  type        = string
  description = "Front-channel logout URL. Entra ID supports a single value."
}
