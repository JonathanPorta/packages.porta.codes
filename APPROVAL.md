# Approval package — packages.porta.codes

One decision covering everything the Linux packaging pilot still needs from
the owner (blessed-cicd #303, #74, #81). Nothing below exists yet: no
repository, bucket, Worker, role, key, BWS project or token has been created.
Approve, amend or refuse each numbered item; items 1–4 are needed for the first
publication, item 5 only if the proof in 5 shows it is required.

## 1. Domain and repository

| | Proposal |
|---|---|
| Hostname | `packages.porta.codes` (zone `porta.codes`, already on Cloudflare) |
| Owner repository | new `JonathanPorta/packages.porta.codes`, default branch `main` — the one infrastructure owner of the bucket, the hostname, the Worker and the repository key (PR-1) |
| Visibility | **public** (recommended). Everything in it is public by design — inventory, public keys, workflows, the served repository — and no workflow prints a secret. Public also makes GitHub-hosted runners free, including **native arm64** runners, so the Debian arm64 / Fedora aarch64 rows could get native client evidence instead of "not exercised here". Private works too; then arm64 rows stay producer-emulated evidence only. |
| Rulesets on `main` | require a PR, one approving review, and the `CI` required check; no force-push, no deletion |

## 2. Infrastructure and expected cost

Terraform in this repository (`main.tf`, state `deployments-state/terraform-state/packages.porta.codes`), applied with `make plan TF_WORKSPACE=production` → review `plan.out` → `make deploy`:

| Resource | Details |
|---|---|
| S3 bucket `packages.porta.codes` (website) | `JonathanPorta/s3-static-site/aws` 1.5.0, as the portfolio's other static sites; public read |
| Bucket policy guards (publisher principal only) | every `PutObject` except `_state/generation.json` must carry `If-None-Match` (condition key `s3:if-none-match`); the pointer must carry `If-Match` or `If-None-Match` (`s3:if-match` / `s3:if-none-match`); `DeleteObject`/`DeleteObjectVersion` denied. AWS documents both keys for enforcing conditional writes; a side effect is that `CopyObject` into the bucket is refused, which nothing uses. |
| Cloudflare DNS | `packages.porta.codes` CNAME → the bucket's website endpoint, **proxied** |
| Cloudflare Worker `packages-porta-codes-router` | the vendored blessed `pkgrepo-router.js` (module), route `packages.porta.codes/*`, one plain-text binding `ORIGIN=http://<bucket website endpoint>`, compatibility date `2026-09-01`, flag `cache_option_enabled` (default since 2024-11-11; listed so the `cache: "no-store"` pointer read is explicit). **No KV, Durable Object, database, lease or secret.** Read-only: GET/HEAD only. |
| Provider change | Cloudflare provider `~> 5.0` in this repo (the portfolio's proofglass already uses 5.x); `better-uptime` `~> 0.3.15` as the static-site module requires |

Credential needed to apply: the operator's Cloudflare API token must allow
**Workers Scripts: Edit** (account), **Workers Routes: Edit** and **DNS: Edit**
(zone `porta.codes`). If the existing Terraform token lacks the Workers
permissions, that is part of this approval.

### Expected monthly cost

Prices (2026-09): S3 Standard us-east-1 $0.023/GB-month, PUT $0.005 per 1,000,
GET $0.0004 per 1,000, internet egress $0.09/GB after the account-wide
100 GB/month free allowance ([AWS S3 pricing](https://aws.amazon.com/s3/pricing/));
Cloudflare Workers Free 100,000 requests/day (beyond it requests error), Paid
$5/month minimum with 10 M requests included, then $0.30 per million
([Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/)).

| Item | Assumption | Cost |
|---|---|---|
| S3 storage | ≈150 MB per release across kioskd (deb+rpm, amd64+arm64), corpus (deb+rpm, 2 arches) and keysprout (rpm); every version retained; ~20 releases in year one → ≤3 GB | ≤ $0.07 |
| S3 PUTs | ~100 objects per publication, a few publications a month | < $0.01 |
| S3 GETs | every routed entrypoint = 1 pointer GET + 1 object GET; generation objects are edge-cached as immutable; tens of devices checking hourly → < 100 k GETs | < $0.05 |
| Egress S3 → Cloudflare | package bytes once per edge location per version (immutable, cached); well under 100 GB | $0 (free allowance), ≤ $0.50 if the allowance is already used elsewhere |
| Cloudflare DNS + proxy | existing zone | $0 |
| Worker | every request to the hostname runs it; expected < 5,000/day | $0 on Free; **$0 marginal** if the account is already on Workers Paid; $5/month only if Paid must be enabled for this alone |

**Expected: under $1/month. Worst plausible: about $5/month** (Workers Paid
enabled solely for this). Exceeding the Free plan fails closed — clients get
errors, never wrong data.

## 3. AWS publisher role

Created once, out of band (the same bootstrap-owned pattern as docsort.io's
surface publication); Terraform then owns only its inline permissions.

Role name `packages-porta-codes-publisher`. Trust policy, verbatim
(`<ACCOUNT_ID>` = the portfolio account):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:JonathanPorta/packages.porta.codes:environment:repository-publication"
        }
      }
    }
  ]
}
```

Permissions (Terraform `aws_iam_role_policy.publisher`), verbatim as rendered:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "ReadAndWriteRepositoryObjects", "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": "arn:aws:s3:::packages.porta.codes/*" },
    { "Sid": "DistinguishMissingFromForbidden", "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::packages.porta.codes" }
  ]
}
```

Bucket-policy guards added by Terraform (deny statements, principal = that role):

```json
[
  { "Sid": "EveryObjectButThePointerIsCreateOnly", "Effect": "Deny", "Action": "s3:PutObject",
    "NotResource": "arn:aws:s3:::packages.porta.codes/_state/generation.json",
    "Condition": { "Null": { "s3:if-none-match": "true" } } },
  { "Sid": "ThePointerIsOnlyReplacedConditionally", "Effect": "Deny", "Action": "s3:PutObject",
    "Resource": "arn:aws:s3:::packages.porta.codes/_state/generation.json",
    "Condition": { "Null": { "s3:if-match": "true", "s3:if-none-match": "true" } } },
  { "Sid": "PublisherNeverDeletes", "Effect": "Deny",
    "Action": ["s3:DeleteObject", "s3:DeleteObjectVersion"],
    "Resource": "arn:aws:s3:::packages.porta.codes/*" }
]
```

Repository variables: `AWS_ACCOUNT_ID`, `AWS_REGION`.

## 4. Signing and read authority

**Existing identities are kept.** Nothing here rotates, replaces or moves an
existing key.

| Key / credential | New or existing | Where it lives | Machine account |
|---|---|---|---|
| kioskd candidate signing key (Ed25519, key id `kioskitd-2026-01`, secret `RELEASE_SIGNING_KEY`) | **EXISTING — reused as is** | kioskd's existing BWS project and loader; its public half is already this repo's `keys/candidates/kioskd.json` (from kioskd `release-trusted-keys.json` @ 22b40ae) | unchanged |
| keysprout `RELEASE_TOKEN` | existing, unrelated | untouched | unchanged |
| Repository metadata key (OpenPGP RSA 4096) | NEW | BWS project `packages-porta-codes-repo-signing`, Environment `repository-signing` | `packages-porta-codes-repo-signing-ci` |
| Candidate read token (fine-grained PAT: **Contents: read** on kioskd, corpus, keysprout; nothing else) | NEW (created in the GitHub UI) | BWS project `packages-porta-codes-candidate-ingest`, Environment `candidate-ingest` | `packages-porta-codes-candidate-ingest-ci` |
| kioskd RPM signing key (OpenPGP RSA 4096; LP-9) | NEW — kioskd has no RPM key today | kioskd: BWS project `kioskd-rpm-signing`, Environment `rpm-signing` | `kioskd-rpm-signing-ci` |
| corpus RPM signing key | NEW | corpus: `corpus-rpm-signing`, Environment `rpm-signing` | `corpus-rpm-signing-ci` |
| keysprout RPM signing key | NEW | keysprout: `keysprout-rpm-signing`, Environment `rpm-signing` | `keysprout-rpm-signing-ci` |
| corpus candidate signing key (Ed25519) | NEW — corpus has none | corpus: `corpus-release-signing`, Environment `release-signing` | `corpus-release-signing-ci` |
| keysprout candidate signing key (Ed25519) | NEW — keysprout has none | keysprout: `keysprout-release-signing`, Environment `release-signing` | `keysprout-release-signing-ci` |
| Publication | none — GitHub OIDC to the role in §3 | Environment `repository-publication` | — |

Every Environment's deployment branch policy: **`main` only**. Producer
Environments additionally accept their release tags (`v*`) if their release
workflow runs on tags.

### Ordered steps

| # | Who | Step |
|---|---|---|
| 1 | owner | Approve §1–§4 (or amend). |
| 2 | me | Create the repository (public unless you say otherwise), push `main`, create the three Environments and the `main` ruleset. |
| 3 | owner | On a trusted workstation: `scripts/provision/generate-keys.sh ~/ppc-keys-$(date +%F)`. It writes the six new private keys 0600 into that new directory, prints **only** fingerprints and the exact commands below, uploads nothing and touches no existing key. |
| 4 | me | Commit the public halves and fingerprints it printed (`keys/`, `inventory/layout.json`); producers' public halves go in their release-ceremony PRs. |
| 5 | owner | For each new domain, preview then create it with the existing bootstrapper (`scripts/bws/bootstrap.sh`, bws 1.9.1; it names the machine account `<app-name>-ci`):<br>`scripts/bws/bootstrap.sh --app-name packages-porta-codes-repo-signing --secrets-list .bws/repository-signing.list --loader .github/actions/load-repository-signing/action.yml --project-id-file .bws/repository-signing.env --gh-environments repository-signing --plan` (review) then the same with `--no-secret-values`;<br>likewise `packages-porta-codes-candidate-ingest` (`candidate-ingest`), and in each producer repo `<repo>-rpm-signing` (`rpm-signing`) and, for corpus and keysprout, `<repo>-release-signing` (`release-signing`). Machine-account tokens are created in the Bitwarden web UI. |
| 6 | owner | Paste each private file's **contents** into its Bitwarden secret in the web UI (never a terminal argument, never chat); create the candidate-read PAT in the GitHub UI and paste it the same way. Then shred the directory (`rm -P` on macOS). |
| 7 | owner | Create the IAM role with the §3 trust policy (or authorize me to run exactly that `aws iam create-role`); set `AWS_ACCOUNT_ID`, `AWS_REGION`. |
| 8 | me | `make plan TF_WORKSPACE=production`, post `plan.out` for review; after approval `make deploy`. |
| 9 | me | Producer release-ceremony PRs (RPM finalization with signing-v0.3.0 `rpm-finalize.sh`; candidate signing for corpus/keysprout), each through review. |
| 10 | me | Admit the first candidates, prove the admission-PR check behaviour (§5), merge through review, and watch **Publish** through read-back; record the evidence against PR-2…PR-15. |

## 5. Admission PRs and required checks

`admit-candidate.yml` opens each admission PR with `GITHUB_TOKEN`. GitHub does
not start `pull_request` workflows for events caused by `GITHUB_TOKEN`, so the
PR's required `CI` check will not appear on its own. DocSort already showed
that a check produced by a `workflow_dispatch` run on the branch does **not**
satisfy the PR ruleset, so that is not assumed to work here.

Plan, with no new credential:

1. Prove it with **one real admission PR**: record the ruleset's required-check
   state on that PR (`gh pr checks`, the merge box) as opened by `GITHUB_TOKEN`.
2. Established mechanism first: the reviewing human **closes and reopens** the
   PR (a human event, which starts `pull_request` CI on the exact head) as part
   of the review they already give. Record whether the resulting `CI` check
   satisfies the ruleset.
3. Only if (2) does not satisfy the ruleset in practice, request one more
   authority domain — `packages-porta-codes-admission-pr` with machine account
   `packages-porta-codes-admission-pr-ci`, holding a fine-grained PAT (or App
   token) limited to **Pull requests: write** and **Contents: write** on this
   repository only — so the PR is opened by an identity whose events start CI.
   That request comes with the evidence from (1) and (2); it is not part of this
   approval.
