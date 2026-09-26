terraform {
  required_version = ">= 1.10" # use_lockfile
  required_providers {
    aws          = { source = "hashicorp/aws", version = "~> 4.8.0" }
    cloudflare   = { source = "cloudflare/cloudflare", version = "~> 5.0" }
    betteruptime = { source = "BetterStackHQ/better-uptime", version = "~> 0.3.15" }
  }
}
