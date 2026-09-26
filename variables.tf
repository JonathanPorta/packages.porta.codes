variable "base_domain" {
  type        = string
  description = "Zone the package repository hostname lives in."
  default     = "porta.codes"
}

variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare account that owns the porta.codes zone; the router Worker lives there."
}

variable "create_github_oidc_provider" {
  type        = bool
  description = <<-EOT
    Create the account-global GitHub Actions OIDC provider instead of looking
    it up. It is shared by every repo that uses GitHub OIDC (docsort.io already
    relies on it), so the default is to look it up; the plan fails if absent.
  EOT
  default     = false
}
