# packages.porta.codes — ONE infrastructure owner for the bucket, the CDN
# hostname and the publisher's authority (blessed releases.surfaces@1,
# releases.package-repositories@1 PR-1). Reuses the portfolio's static-site
# module and docsort.io's surface-publication pattern: a bootstrap-owned OIDC
# role whose ONLY permissions are set here, and bucket guards that make S3
# itself refuse any write by the publisher that could replace an object.
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
  # The one object the publisher replaces: the activation pointer. Every
  # other key is create-only (PR-9).
  pointer_arn = "${local.bucket_arn}/_state/generation.json"
  router_name = "packages-porta-codes-router"
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

# Proxied, so the router's route below applies to every request.
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
    text = "http://${module.site.bucket_fqdn}"
  }]
}

resource "cloudflare_workers_route" "router" {
  provider = cloudflare._cloudflare
  zone_id  = data.cloudflare_zone.zone.zone_id
  pattern  = "${local.hostname}/*"
  script   = cloudflare_workers_script.router.script_name
}

# The publisher role is created once, out of band, with a trust policy scoped
# to repo:JonathanPorta/packages.porta.codes:environment:repository-publication
# (see README "Provisioning"). Terraform owns only its permissions.
data "aws_iam_role" "publisher" {
  provider = aws._aws
  name     = local.publisher_role
}

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

output "router" {
  value = "${cloudflare_workers_script.router.script_name} on ${cloudflare_workers_route.router.pattern}"
}
