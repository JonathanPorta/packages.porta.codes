# Approval package — packages.porta.codes

**Status: APPROVED WITH CORRECTIONS (owner, 2026-09-26).** Approved: the
public repository with a protected `main`, the S3 bucket, Cloudflare DNS and
the read-only Worker, the scoped AWS publisher role, and the separated BWS
signing and ingestion domains; the candidate-read token (Contents: read on the
three producers only). Corrections, now applied below and in the code:

1. **Environments match each producer's trusted release workflow** — kioskd's
   `rpm-signing` allows tag `v*` only (it releases on `v*` tags, and its signing
   job asserts the tagged commit is on `main`); corpus and keysprout stay
   `main`; no Environment is broadened (`scripts/provision/github-environments.sh`).
2. **The Worker's ORIGIN is the certificate-valid HTTPS S3 REST endpoint**
   (path-style), never the HTTP website endpoint.
3. **The Worker route fails closed** when the Free plan allowance is exhausted;
   Free plan only, no paid services.
4. **The publisher role is created by Terraform**, inside the reviewed plan (the
   plan is reviewed before any apply).

The complete owner walkthrough for keys and BWS is **[`PROVISIONING.md`](PROVISIONING.md)**.
No separate PR-opening credential is requested (§5).

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
| Cloudflare DNS | `packages.porta.codes` CNAME, **proxied**. Its target (the bucket's website endpoint, the module's output) is never reached: the Worker route `packages.porta.codes/*` answers every request, and fails CLOSED (Cloudflare error 1027) if the Free allowance is exhausted — nothing is served around the router |
| Cloudflare Worker `packages-porta-codes-router` | the vendored blessed `pkgrepo-router.js` (release-v0.5.0, module), route `packages.porta.codes/*`, one plain-text binding `ORIGIN=https://s3.<region>.amazonaws.com/packages.porta.codes` — the bucket's **S3 REST endpoint over HTTPS, path-style** (the bucket name has dots, so the virtual-hosted name does not match S3's wildcard certificate; AWS documents path-style as supported, its deprecation delayed indefinitely). The HTTP-only website endpoint is never fetched. Compatibility date `2026-09-01`, flag `cache_option_enabled`. **No KV, Durable Object, database, lease or secret.** Read-only: GET/HEAD only. Route **fails closed** (`request_limit_fail_open = false`, the API default — the provider cannot set it, so `make verify-edge` asserts it from the live API) |
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

These are **estimates, not maxima**. Expected: under $1/month; plausible high:
about $5/month (Workers Paid enabled solely for this). What is actually
enforced, and what is not:

| Control | Enforced? | Effect |
|---|---|---|
| Cloudflare Workers **Free** plan (recommended to stay on it) | **yes — a hard cap** | above 100,000 requests/day the Worker errors instead of billing: Worker cost is exactly $0, and excess traffic fails closed (errors, never wrong data) |
| S3 storage / requests / egress | **no cap exists** in S3 | bounded in practice by the retention above and by edge caching of immutable objects; every write is a reviewed publication |
| AWS Budget alert on the bucket's cost-allocation tag (optional, needs your OK) | alert only, not a cap | email when month-to-date passes e.g. $2 |

So a maximum can only be stated for the Worker ($0 on Free). S3 has no
enforced ceiling; the numbers above are estimates.

## 3. AWS publisher role

Created by Terraform in the reviewed plan (owner-authorized). Terraform is
applied only by the operator from a workstation after the plan is reviewed; no
workflow has IAM or Terraform authority, so the first-writer race that makes
docsort.io adopt its role read-only does not arise here. The account-global
GitHub OIDC provider is looked up by its ARN (docsort.io already uses it) and
is never re-created.

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

### Routing authority (separate from publishing)

The router holds **no credential at all**. It reads the bucket anonymously
through its HTTPS S3 REST endpoint — the same public `s3:GetObject` the bucket
policy grants everyone — and can only GET/HEAD. (Without anonymous
`s3:ListBucket`, a missing key is a 403: the router answers 404 for a missing
entrypoint, and passes a 403 through for any other missing path.) It cannot write, list or delete anything. The only authority involved
is **deploying** it: the operator's Cloudflare API token used by `make deploy`
(Workers Scripts: Edit, Workers Routes: Edit, DNS: Edit on `porta.codes`). That
token is never given to CI or to the publisher role, and the publisher role has
no Cloudflare access. Changing the router therefore takes a reviewed Terraform
change applied by the operator, never a publication.

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

Environment deployment policies match each trusted release workflow exactly:
`main` for this repository's three Environments and for corpus and keysprout;
**tag `v*` only** for kioskd's `rpm-signing` (see PROVISIONING.md §0).

### Ordered steps

| # | Who | Step |
|---|---|---|
| 1 | owner | ✅ Approved with corrections (2026-09-26). |
| 2 | me | Create the public repository, push `main` through review, set its ruleset and create every Environment (`scripts/provision/github-environments.sh --apply`); open the producers' declaration PRs (`.bws` lists, loaders, Environments) through review. |
| 3 | me | `make plan TF_WORKSPACE=production` — bucket, guards, DNS, Worker, route **and the publisher role** — and post `plan.out` for review. |
| 4 | owner | Review and approve that plan. Then I run `make deploy` and `make verify-edge`. |
| 5 | owner | Follow **PROVISIONING.md** §1–§6 (key generation, the read-only PAT, seven bootstrapper runs, web-UI secret entry, cleanup). |
| 6 | me | Commit public halves, fingerprints and the filled loader UUIDs; producer release-ceremony PRs (RPM finalization with signing-v0.3.0; candidate signing for corpus/keysprout; kioskd's tag job asserts ancestry of `main`), each through review. |
| 7 | me | Admit the first candidates, prove the admission-PR check path (§5), merge through review, watch **Publish** through read-back, then real APT/DNF evidence against `https://packages.porta.codes/`; record it against PR-2…PR-15. |

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

## 6. Operating procedures

- **Publish.** A reviewed inventory PR merges → `publish.yml`: fetch and check
  every byte against the inventory → generate (no secret) → sign (repository key
  only) → verify (public keys only) → staged install/upgrade through the router
  → create every object once → ONE conditional write of the pointer bound to the
  activation read at plan time → read-back through `https://packages.porta.codes/`
  with real apt/dnf. The new activation revision is in the run summary.
- **Retry / resume.** Re-run the workflow. Objects already created are skipped;
  missing ones are created; nothing is overwritten. A run that lost the pointer
  comparison fails and is never retried as is — the next run re-plans against
  the live activation.
- **Replay.** Re-running for an inventory already live is a no-op (no objects,
  no activation).
- **Rollback.** Revert the inventory change in a reviewed PR; publishing it
  activates a generation of the older inventory through a NEW activation
  revision (every package it references is still stored; old pointer bytes are
  never restored). Installed clients are not downgraded (PR-13).
- **Recovery.** Origin errors are never cached at the edge, so a transient S3
  failure recovers on the next request. A DNF client that fetched `repomd.xml`
  and its signature across an activation refuses the pair and recovers on
  refresh. If a publication fails after creating objects but before activation,
  nothing is served differently; re-run.

## 7. Links

- Tooling: blessed-cicd #308 (merged `a250255`), released as
  [release-v0.5.0](https://github.com/JonathanPorta/blessed-cicd/releases/tag/release-v0.5.0);
  signing-v0.3.0 (#306).
- Standard: `releases.package-repositories@1` (PR-7/8/9/10/13 as amended in #308),
  `releases.linux-packaging@1`, `releases.surfaces@1`.
- Plan and clause→evidence matrix: blessed-cicd
  `tasks/project-linux-packaging-pilot.md` (update PR linked in the request).
- This repository (local until step 2): `main.tf` (bucket, guards, DNS,
  Worker), `release-surfaces.yaml`, `.github/workflows/{ci,admit-candidate,publish}.yml`,
  `scripts/provision/generate-keys.sh`, `tests/e2e.sh`.
