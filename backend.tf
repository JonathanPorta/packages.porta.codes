terraform {
  backend "s3" {
    bucket = "deployments-state"
    key    = "terraform-state/packages.porta.codes"
  }
}
