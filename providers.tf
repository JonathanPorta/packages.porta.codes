# Credentials come from the environment, never from this configuration:
# AWS from the job's OIDC role session (aws-actions/configure-aws-credentials),
# Cloudflare from CLOUDFLARE_API_TOKEN (BWS default domain, loaded by
# .github/actions/load-secrets).
provider "aws" {
  alias = "_aws"
}
provider "cloudflare" {
  alias = "_cloudflare"
}
# The static-site module declares a Better Uptime monitor, off here
# (monitoring = false). The provider still requires api_token to configure, and
# with zero monitors it never calls the API, so an inert value is given rather
# than loading a monitoring secret this stack does not use. Turning monitoring
# on means replacing this with a real token from BWS.
provider "betteruptime" {
  alias     = "_betteruptime"
  api_token = "unused-monitoring-disabled"
}
