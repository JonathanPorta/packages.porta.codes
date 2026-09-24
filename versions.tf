terraform {
  required_version = ">= 1.5"
  required_providers {
    aws          = { source = "hashicorp/aws", version = "~> 4.8.0" }
    cloudflare   = { source = "cloudflare/cloudflare", version = "3.13.0" }
    betteruptime = { source = "BetterStackHQ/better-uptime", version = "0.3.13" }
  }
}
