variable "base_domain" {
  type        = string
  description = "Zone the package repository hostname lives in."
  default     = "porta.codes"
}

variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare account that owns the porta.codes zone; the router Worker lives there."
}
