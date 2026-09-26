# packages.porta.codes — ONE infrastructure owner for the bucket, the CDN
# hostname and the publisher's authority (blessed releases.surfaces@1,
# releases.package-repositories@1 PR-1). Reuses the portfolio's static-site
# module and docsort.io's surface-publication guards: an OIDC role bound to one
# repository and one GitHub Environment, and bucket guards that make S3 itself
# refuse any write by the publisher that could replace an object.
#
# TERRAFORM RUNS IN CI WITH GITHUB OIDC ONLY (blessed-cicd #9): no AWS key
# exists for this stack anywhere. Two per-authority roles run it —
#   packages-porta-codes-terraform-plan   read-only, Environment infrastructure-plan
#   packages-porta-codes-terraform-apply  this stack only, Environment infrastructure
# — and a third, packages-porta-codes-publisher, publishes packages.
#
# ROLE CREATION AND TRUST ARE BOOTSTRAP-OWNED (blessed-cicd #239), created by
# the operator with scripts/provision/aws-oidc-bootstrap.sh under the
# operator's SSO identity, never by an identity Terraform runs as. Terraform
# ADOPTS all three roles and the account-global GitHub OIDC provider by exact
# ARN (data sources below; a missing one fails the plan). The ONE IAM object
# it mutates is the publisher role's INLINE policy, and the apply role may only
# Get/Put/Delete that one role's inline policy — capped, in turn, by the
# publisher's bootstrap-owned permissions boundary. This closes docsort.io's
# first-writer race: no identity reachable from a workflow can create a role.
#
# Layout the publisher writes (blessed pkgrepo-publish.sh, release 0.5.0):
#   shared immutables at their advertised paths (packages, by-hash indexes,
#   checksum-named repodata), each generation's entrypoints under
#   _generations/<generation_id>/, generation records under
#   _state/generations/, and ONE replaced object: the activation pointer
#   _state/generation.json. Clients reach entrypoints at stable URLs through
#   the read-only router Worker below (blessed pkgrepo-router.js).
locals {
  hostname       = "packages.${var.base_domain}"
  bucket_arn     = "arn:aws:s3:::packages.${var.base_domain}"
  publisher_role = "packages-porta-codes-publisher"
  plan_role      = "packages-porta-codes-terraform-plan"
  apply_role     = "packages-porta-codes-terraform-apply"
  # The one object the publisher replaces: the activation pointer. Every
  # other key is create-only (PR-9).
  pointer_arn = "${local.bucket_arn}/_state/generation.json"
  router_name = "packages-porta-codes-router"
  # The router's origin: the bucket's S3 REST endpoint over HTTPS, PATH-STYLE.
  # The bucket name contains dots, so the virtual-hosted name
  # packages.porta.codes.s3.<region>.amazonaws.com does not match S3's
  # wildcard certificate; path-style keeps a certificate-valid HTTPS origin.
  # The website endpoint (HTTP only) is never used by the router.
  router_origin = "https://s3.${data.aws_region.current.name}.amazonaws.com/${module.site.bucket}"
  github_oidc_provider_arn = format(
    "arn:%s:iam::%s:oidc-provider/token.actions.githubusercontent.com",
    data.aws_partition.current.partition,
    data.aws_caller_identity.current.account_id,
  )
}

data "aws_region" "current" {
  provider = aws._aws
}
data "aws_caller_identity" "current" {
  provider = aws._aws
}
data "aws_partition" "current" {
  provider = aws._aws
}

module "site" {
  source                 = "JonathanPorta/s3-static-site/aws"
  version                = "1.5.0"
  hostname               = local.hostname
  environment            = "production"
  source_files           = "${path.module}/site"
  monitoring             = false
  extra_policy_documents = [data.aws_iam_policy_document.publisher_guards.json]
  providers              = { aws = aws._aws, betteruptime = betteruptime._betteruptime }
}

data "cloudflare_zone" "zone" {
  provider = cloudflare._cloudflare
  filter   = { name = var.base_domain }
}

# Proxied, so the router's route below applies to every request. The record
# needs SOME target for Cloudflare to proxy; it points at the bucket's website
# endpoint only because that is the module's output, and nothing is ever served
# from it: the route packages.porta.codes/* sends every request to the router,
# and the route fails CLOSED if the Free plan's daily allowance is exhausted
# (request_limit_fail_open = false — the API default; the provider cannot set
# it, `make verify-edge` asserts it). So a request is answered by the router
# or refused with Cloudflare error 1027, never served around the router.
resource "cloudflare_dns_record" "packages" {
  provider = cloudflare._cloudflare
  zone_id  = data.cloudflare_zone.zone.zone_id
  name     = local.hostname
  content  = module.site.bucket_fqdn
  type     = "CNAME"
  ttl      = 1
  proxied  = true
}

# The read-only router (blessed pkgrepo-router.js, vendored at
# scripts/release/): stable entrypoint URLs → the active generation's prefix,
# reading the pointer uncached on every request; every other path passes
# through to the bucket. No KV, Durable Object, database or other binding —
# ORIGIN is its only configuration. `cache_option_enabled` lets it pass
# `cache: "no-store"` to fetch(); it is the default from compatibility date
# 2024-11-11 and is listed so the requirement is explicit.
resource "cloudflare_workers_script" "router" {
  provider            = cloudflare._cloudflare
  account_id          = var.cloudflare_account_id
  script_name         = local.router_name
  content             = file("${path.module}/scripts/release/pkgrepo-router.js")
  main_module         = "pkgrepo-router.js"
  compatibility_date  = "2026-09-01"
  compatibility_flags = ["cache_option_enabled"]
  bindings = [{
    name = "ORIGIN"
    type = "plain_text"
    text = local.router_origin
  }]
}

# Fail-closed on exhausted allowance: the route's request_limit_fail_open is
# false (API default; not representable in this provider — verified live by
# `make verify-edge`). Workers Free plan only.
resource "cloudflare_workers_route" "router" {
  provider = cloudflare._cloudflare
  zone_id  = data.cloudflare_zone.zone.zone_id
  pattern  = "${local.hostname}/*"
  script   = cloudflare_workers_script.router.script_name
}

# ── adopted, bootstrap-owned identity objects ────────────────────────────────
# The account-global GitHub OIDC provider, by its deterministic ARN (no
# iam:ListOpenIDConnectProviders), and the three roles. Their trust policies
# and boundaries are created and verified by scripts/provision/aws-oidc-bootstrap.sh;
# Terraform only reads them, so a missing or renamed one fails the plan.
data "aws_iam_openid_connect_provider" "github" {
  provider = aws._aws
  arn      = local.github_oidc_provider_arn
}

data "aws_iam_role" "publisher" {
  provider = aws._aws
  name     = local.publisher_role
}

data "aws_iam_role" "terraform_plan" {
  provider = aws._aws
  name     = local.plan_role
}

data "aws_iam_role" "terraform_apply" {
  provider = aws._aws
  name     = local.apply_role
}

# The publisher's permissions — the one IAM object this configuration owns.
# Capped by the role's bootstrap-owned boundary
# (policies/packages-porta-codes-publisher-boundary.json), so the apply role
# cannot widen publication beyond it even by editing this policy.
data "aws_iam_policy_document" "publisher_permissions" {
  statement {
    sid       = "ReadAndWriteRepositoryObjects"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${local.bucket_arn}/*"]
  }
  # Without ListBucket, S3 answers a missing key with 403, not 404, and the
  # publisher could not tell "absent" from "forbidden".
  statement {
    sid       = "DistinguishMissingFromForbidden"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
  }
}

resource "aws_iam_role_policy" "publisher" {
  provider = aws._aws
  name     = "package-repository-publication"
  role     = data.aws_iam_role.publisher.id
  policy   = data.aws_iam_policy_document.publisher_permissions.json
}

# S3 enforces conditional writes through the s3:if-none-match and s3:if-match
# bucket-policy condition keys (AWS, "Enforce conditional writes on Amazon S3
# buckets"). A consequence: CopyObject into these keys is refused, which the
# publisher never uses.
data "aws_iam_policy_document" "publisher_guards" {
  statement {
    sid           = "EveryObjectButThePointerIsCreateOnly"
    effect        = "Deny"
    actions       = ["s3:PutObject"]
    not_resources = [local.pointer_arn]
    principals {
      type        = "AWS"
      identifiers = [data.aws_iam_role.publisher.arn]
    }
    condition {
      test     = "Null"
      variable = "s3:if-none-match"
      values   = ["true"]
    }
  }
  # The pointer is written only conditionally: If-Match on the version the
  # plan read, or If-None-Match before the first activation. Both conditions
  # below must hold for the deny — i.e. neither header present.
  statement {
    sid       = "ThePointerIsOnlyReplacedConditionally"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = [local.pointer_arn]
    principals {
      type        = "AWS"
      identifiers = [data.aws_iam_role.publisher.arn]
    }
    condition {
      test     = "Null"
      variable = "s3:if-match"
      values   = ["true"]
    }
    condition {
      test     = "Null"
      variable = "s3:if-none-match"
      values   = ["true"]
    }
  }
  statement {
    sid       = "PublisherNeverDeletes"
    effect    = "Deny"
    actions   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
    resources = ["${local.bucket_arn}/*"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_iam_role.publisher.arn]
    }
  }
}

output "hostname" {
  value = local.hostname
}

output "publisher_role_arn" {
  value = data.aws_iam_role.publisher.arn
}

output "terraform_role_arns" {
  value = {
    plan  = data.aws_iam_role.terraform_plan.arn
    apply = data.aws_iam_role.terraform_apply.arn
  }
}

output "github_oidc_provider_arn" {
  value = data.aws_iam_openid_connect_provider.github.arn
}

output "router_origin" {
  value = local.router_origin
}

output "router" {
  value = "${cloudflare_workers_script.router.script_name} on ${cloudflare_workers_route.router.pattern}"
}
