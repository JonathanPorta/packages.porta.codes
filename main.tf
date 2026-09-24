# packages.porta.codes — ONE infrastructure owner for the bucket, the CDN
# hostname and the publisher's authority (blessed releases.surfaces@1,
# releases.package-repositories@1 PR-1). Reuses the portfolio's static-site
# module and docsort.io's surface-publication pattern: a bootstrap-owned OIDC
# role whose ONLY permissions are set here, and bucket guards that make S3
# itself refuse to replace or delete immutable repository objects.
locals {
  hostname       = "packages.${var.base_domain}"
  bucket_arn     = "arn:aws:s3:::packages.${var.base_domain}"
  publisher_role = "packages-porta-codes-publisher"
  # Immutable repository objects (PR-9): packages, by-hash indexes,
  # checksum-named DNF repodata (every name contains '-'; repomd.xml does not),
  # published keys, and generation records. The publisher may only CREATE them.
  immutable_objects = [
    "${local.bucket_arn}/apt/*/pool/*",
    "${local.bucket_arn}/apt/*/by-hash/*",
    "${local.bucket_arn}/rpm/*/Packages/*",
    "${local.bucket_arn}/rpm/*/repodata/*-*",
    "${local.bucket_arn}/keys/*",
    "${local.bucket_arn}/_state/generations/*",
  ]
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
  name     = var.base_domain
}

resource "cloudflare_record" "packages" {
  provider = cloudflare._cloudflare
  zone_id  = data.cloudflare_zone.zone.id
  name     = local.hostname
  value    = module.site.bucket_fqdn
  type     = "CNAME"
  ttl      = 1
  proxied  = true
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

data "aws_iam_policy_document" "publisher_guards" {
  statement {
    sid       = "ImmutableObjectsAreCreateOnly"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = local.immutable_objects
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
