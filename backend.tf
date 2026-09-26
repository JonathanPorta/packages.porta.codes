terraform {
  backend "s3" {
    bucket = "deployments-state"
    key    = "terraform-state/packages.porta.codes"
    # The DEFAULT workspace only: a named workspace makes Terraform write its
    # first state object when selected, which the read-only plan role cannot
    # (and must not) do. Locking uses an S3 lockfile beside the state; only the
    # apply role may write it — plans run with -lock=false.
    use_lockfile = true
  }
}
