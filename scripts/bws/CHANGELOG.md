# Changelog — `bws/` scripts

Canonical Bitwarden Secrets Manager scripts. SemVer; each release is tagged
`bws-v<version>` with the SHA-256 set-hash (of `MANIFEST.sha256`) in the notes.

## 1.9.1

### Fixed

- **The `--no-secret-values` summary described a loader ceremony a
  delivery-only consumer does not have** (#294). For a declaration whose every
  key is a managed delivery the block still announced a created
  `BWS_ACCESS_TOKEN`, an updated `.env-sample` and deferred `action.yml`
  UUIDs — none of which happen — and pointed at a `git diff` that is always
  empty, contradicting the `not applicable` rows printed immediately above it.
  Phase 1 now reports what actually happened (project ensured; no machine
  account, token or loader for this repository), phase 2 says the next run
  proves the credential, records its expiry and delivers and verifies the
  managed copy, and the file-diff note is printed only where files are
  written. A run with no skipped secrets now also states that deliveries were
  reconciled. Mixed declarations keep the loader wording unchanged.

## 1.9.0

### Added

- **Managed Dependabot delivery — `deliver:dependabot@OWNER/REPO`.** Dependabot
  cannot read Bitwarden: the credentials it uses for private registries are
  GitHub *Dependabot secrets*, a namespace no workflow job can see. Until now
  the only way to give it one was an improvised `gh secret set --app dependabot`
  outside the toolkit — no declaration, no source of truth, no verification, no
  rotation path. A key declared with `deliver:dependabot@OWNER/REPO` in
  `.bws-secrets-list` now keeps Bitwarden authoritative and lets `bootstrap.sh`
  maintain the Dependabot secret as a **managed copy**, same name as the key:

  - the parser (`_lib.sh`) validates the field — `dependabot` is the only
    target, the destination must be `OWNER/REPO`, and a key carries at most
    one delivery — and exposes it as `_BWS_PARSED_DELIVER`;
  - the destination is checked against the repository the wizard runs in
    **before** anything is confirmed or mutated; a mismatch is fatal;
  - the copy is written when absent, when the Bitwarden revision is newer than
    the copy (a rotation), or on `--resync-deliveries`; otherwise it is left
    alone, so normal re-runs write nothing. Every write is verified by
    re-reading the destination's `updated_at`;
  - a `github_pat` is proved able to authenticate as its declared `owner:` and
    read every declared `repos:` entry before it is delivered (value-blind:
    the token reaches `curl` through `--config -` on stdin), and the expiry
    GitHub reports for it is recorded in the secret's note as `expires_at=`;
    `--plan` reports OK/WARNING/URGENT/FAIL/EXPIRED from that note with the
    fleet thresholds without touching the value;
  - an unreadable destination is `UNOBSERVABLE`: nothing is written and the
    run exits non-zero. A token that fails its probe is `BLOCKED` and not
    delivered. Partial results are reported per key and the run exits 1.
  - the value flows `bws secret get | jq | gh secret set` (stdin) and is never
    an argument, printed, or written to disk.

- **`--rotate-secret KEY`** — replace the value of an existing Bitwarden
  secret in place (UUID preserved, so every mapping and delivery that names it
  is unchanged), from a hidden prompt or `$KEY`; with `--no-secret-values` it
  prints the vault edit instructions instead. A delivered key is
  re-synchronised in the same run.
- **`--resync-deliveries`** — force every managed copy to be rewritten from
  Bitwarden (after a destination secret was deleted or overwritten by hand).
- **Dependabot-only consumers get no Actions surface.** When every declared key
  is a managed delivery, the machine account, `BWS_ACCESS_TOKEN`, and the
  generated loader are reported `not applicable` and never created: nothing in
  such a repository lets Actions read Bitwarden, so nothing is granted. Mixed
  declarations keep the loader for the loader keys only.
- `load.sh` skips delivered keys (reported as "not loaded"); they are neither
  required nor optional for a shell or Actions consumer.
- Guard rails: `shared` and `deliver:` on one key is a parse error (a shared
  key has no id here to deliver); `--rotate-secret` on a shared key is refused
  up front; an organization `owner:` is accepted by the probe when the
  declared repositories prove readable (the `/user` login is the minting user,
  not the org). The expiry note is edited only when the recorded value
  changes, so an up-to-date run never advances the Bitwarden revision and is
  never mistaken for a rotation on the next run.

### Tests

- `tests/test-bws-dependabot-delivery.sh` (48 assertions, bash 3.2, recording
  fakes for `gh`/`bws`/`curl`, sentinel leak detection) and five parser cases.

## 1.8.1

### Fixed

- **The `--gh-environments` path overwrote `BWS_ACCESS_TOKEN` on every run.** It
  prompted for the deploy machine-account token and called `gh secret set`
  unconditionally, with none of the already-set skip the repository-scoped path
  has always had. That is not a redundant keystroke: a Bitwarden machine-account
  access token is **reveal-once**, and `--no-secret-values` makes two runs the
  normal shape of an environment ceremony — so the second run asked for a value
  the operator could no longer produce. The ways past it were to mint a
  replacement token, keep the reveal-once value lying around, or paste something
  wrong; each one dissolves the boundary the separate authority exists to draw.

  Presence is now established for every named environment **before** anything is
  prompted for or written. Present and no `--rotate-token` keeps the existing
  secret and says how to replace it deliberately; absent prompts once and sets it
  through stdin; `--rotate-token` still replaces it. The repository-scoped path
  is unchanged, and an environment run still never touches the repository secret.

- **A failed `gh secret list --env` read as an empty environment.** The query's
  three outcomes were two: found, and everything else. An expired credential or a
  5xx therefore looked exactly like a missing secret, and the response to a
  missing secret here is to overwrite — with a token that can never be read back.
  An unreadable environment is now reported as `UNOBSERVABLE` and the run aborts
  before the first prompt, so nothing later in the run mutates either.

- **An environment LOOKUP failure read as "does not exist".** Every non-zero
  result from `gh api repos/<repo>/environments/<env>` — 404, authorization
  failure, transport error, 5xx — took the same "does not exist — skipping"
  branch, so classification completed on partial evidence and pass 2 went on to
  prompt for and write another environment's token. An authoritative 404 is now
  the only failure treated as absence; anything else marks the batch
  unobservable and aborts before the first prompt.

  `tests/test-bws-env-token-idempotency.sh` covers absent, present, explicit
  rotation, an unreadable secret list, an unreadable environment lookup, a
  confirmed 404 alongside a provisionable environment, and a mixed pair —
  asserting the prompt count and the exact writes with recording `gh`/`bws`
  fakes.

## 1.8.0

### Added

- **`--plan`** — a genuinely read-only inventory. It performs the same live
  reads a real run performs, so it reports each declared credential as present
  or missing rather than guessing, and it makes no write of any kind: no
  `bws project create`, no `bws secret create`, no `gh secret set`, no prompt,
  no file edit, and no request for a secret value. It ends with one consolidated
  operator block — status per credential and the exact next action — and refuses
  to combine with `--dry-run`, `--rotate-token`, `--no-secret-values`, or
  `--scaffold`.

  `--dry-run` could not do this job. Its contract is "no external calls", which
  is precisely what stops it from answering the only question an operator has
  before a ceremony: which of these already exist?

- **`.bws-app-name`** — an optional tracked, one-line declaration of the
  application identity, consulted after `--app-name` and `$APP_NAME` and before
  the directory basename. Repositories without one are unaffected.

- **`approval:<anchor>`** in `.bws-secrets-list`, and a `repos:` renderer that
  prints GitHub's actual selection options.

### Fixed

- **`bws-plan` overstated its secret-value boundary.** It printed "Will read
  secret VALUES? NO" and "No secret VALUE was requested or read at any point."
  Neither was true: `bws secret list` returns every secret's value — the CLI has
  no listing format that omits it — so the whole document travels the pipe into
  `jq`, which is where the value is projected away. The guarantee that IS true is
  narrower: no value is assigned to a shell variable, passed as an argument,
  printed, or written to disk. That is what the wizard now says. An operator
  deciding whether to run a credential command deserves the real boundary rather
  than a rounder one, and a false process guarantee is worse than a modest true
  one.

- **`bws-plan` reported certainty from incomplete evidence.** The GitHub secret
  check piped `gh secret list` straight into `grep -qx`, so the pipeline's exit
  status was grep's and a FAILED query — expired token, revoked scope, a 5xx —
  produced an empty list and was reported as `MISSING`. The consolidated block
  then went on to declare every credential present and the next action `none`.
  There are three outcomes, not two: the query succeeds and finds the name, it
  succeeds and does not, or it fails. A read-only mode exists to say what is
  true, and "I could not find out" is not "it is not there" — one of those sends
  an operator to create a credential that already exists. The third state is now
  reported as `UNOBSERVABLE`, it suppresses any "fully reconciled" conclusion,
  and it tells the operator not to mint a replacement on the strength of it.
  The GitHub credential's state is also part of the consolidated decision now:
  without it every BWS secret is present and unreachable.

- **Application identity came from `basename $PWD`.** `git worktree add
  ../wt-emit` therefore retargeted an entire ceremony at a BWS project named
  `wt-emit`, and the only way back was to know to pass `--app-name`. Identity
  that a normal clone and an arbitrarily named worktree disagree about is not
  identity. It now comes from `.bws-app-name` when the repository declares one;
  the basename fallback remains for consumers that do not, but the opening block
  now states which source was used.

- **A relative `.bws-secrets-list` resolved against the cwd**, so from any
  subdirectory the file was invisible and the wizard silently ran the static-site
  DEFAULT key set — reporting success over a key set the repository never
  declared. It now resolves against the repository root.

- **The opening block did not say where it was operating.** It now leads with
  mode, checkout, branch, GitHub repo, application identity and its source, BWS
  project, declaration file, and three explicit lines stating whether this
  invocation will change local files, BWS, or GitHub. A bootstrap completed from
  a branch that does not declare a key had nothing to do about it and said
  nothing; naming the branch is what makes that visible.

- **The loader rewriter could not ADD a key.** It only replaced a placeholder
  UUID already present on a line, so a key declared but absent from the loader
  was recorded `not-found` and no edit was made — a status that reads like a
  diagnostic and behaves like a silent no-op, leaving a hand-edit of generated
  YAML as the only way forward. A declared, non-shared key with a resolved id
  and no line now gets one appended, in declaration order, with the existing
  mappings' indentation, never touching a line that already exists. A key whose
  secret is not in BWS still gets no line: a placeholder there would produce a
  tracked diff that looks wired and loads nothing.

- **Generic advice contradicted declared policy.** A declared `expires: 90d` was
  followed two lines later by "1 year is a reasonable default", with nothing
  saying which one bound. Where the repository has declared owner, repos, perms
  or expires, the corresponding generic line is now suppressed.

- **`repos:` rendered scopes GitHub does not offer.** `repos:owner/*` printed as
  "Only these — owner/*", but GitHub's token form has no wildcard: that can only
  be minted as "All repositories". A wildcard now renders as that option by
  name, and the parser refuses one unless it carries an `approval:` anchor
  naming a recorded decision. Duplicate authority fields — two `repos:` on one
  line, rendered as two simultaneously authoritative scopes — are refused too.

- **`bws secret list` output is projected to `{id, key}` at the boundary.** The
  raw document carries every secret's value, and the wizard only ever needs the
  key-to-id mapping.

## 1.7.1

### Fixed

- The **File edits** summary reported the default targets (`.env-sample`,
  `.github/actions/load-secrets/action.yml`) even when `--loader` /
  `--project-id-file` sent the writes elsewhere. The paths written were always
  correct; the plan describing them was not.

  This matters most where the feature is used: the dry run is the operator's
  evidence before any real Bitwarden or GitHub write, and a deployment profile's
  plan naming the validation loader either sends them to the wrong files or makes
  the two profiles' plans indistinguishable. The summary now renders the
  effective targets, repo-relative, falling back to the absolute path when a
  target genuinely lives outside the repository.

## 1.7.0

### Added

- **Deployment profiles** — four opt-in options let one repository carry a second,
  deploy-only secret authority instead of one loader shared by pull-request
  validation and deployment:
  - `--secrets-list PATH` — read a different key declaration (surfaces the
    existing `BWS_SECRETS_LIST_FILE` env var as an explicit flag).
  - `--loader PATH` — write the generated loader somewhere other than
    `.github/actions/load-secrets/action.yml`, so a second profile cannot
    overwrite the first profile's loader.
  - `--project-id-file PATH` — keep the profile's `BWS_PROJECT_ID` out of
    `.env-sample`.
  - `--gh-environments a,b,c` — set `BWS_ACCESS_TOKEN` as a GitHub **Environment**
    secret in each named environment instead of a repository secret. The
    environment path never touches the repository-scoped secret, so a deployment
    profile cannot rotate or overwrite the validation token. Environments must
    already exist; a missing one is reported and skipped.

  `--app-name` already switched the project and machine-account names, so nothing
  was added for those. Every option is opt-in: omitting them all reproduces the
  previous single-profile behaviour exactly, which `tests/test-bws-deploy-profile.sh`
  asserts.

  `--test-scaffold-to` refuses an absolute or parent-traversing `--loader` /
  `--project-id-file` before any file is created: those values would resolve
  outside the scratch root while the summary still claimed every write landed
  beneath it, defeating the isolation that option exists to provide. A relative
  path under the test root stays allowed.

  Motivation: `.github/actions/load-secrets/action.yml` is used by both the
  standards job on every pull request and by deploy workflows. Any deployment
  credential it maps is handed to every pull request, and both jobs presented the
  same repository-scoped token, whose machine account can read the whole project.


## [1.6.2] — 2026-07-31

Corrective release. **The 1.6.1 runtime is safe**; what 1.6.2 corrects is the
release *record*. `bws-v1.6.1` is immutable and cannot be amended, so the
correction ships as a new version.

### What was wrong with the 1.6.1 record

1.6.1 classified pipeline-free `PROVEN_TARGETS` / `VERSION` matching as an
exploitable **eighth defect** — a SIGPIPE race under `pipefail` that could refuse
a genuinely proven target. **It is not exploitable.** Both values are constrained
to **one physical line** by the exactly-one-declaration checks, and `grep -q`
cannot exit part-way through a line: it must read the whole record before it can
evaluate the pattern, so the reader never goes away early and the producer never
receives SIGPIPE.

Measured rather than reasoned:

| Input shape | Pipeline status |
|---|---|
| single line, ~1.2 MB, match in the first token | `0` |
| the same content as **multiple lines**, match on line 1 | `141` — producer takes SIGPIPE, fails under `pipefail` |
| mutated production membership pipeline, 23 KB → 188 KB, match first | **0 spurious refusals at every size** |

### Correct disposition

**Seven post-publication defects, plus one defensive hardening.**

The seven corrections carried by 1.6.1 stand unchanged: fail-closed on missing or
empty proof metadata; exactly-one `PROVEN_TARGETS`; exactly-one bare-semver
`VERSION` validated before network access; bash 3.2 compatibility with correct
diagnostic flag names; removal of active direct-`sm-action` documentation;
reconciliation of the proposal's bridge states; and duplicate digest rows failing
closed.

The **eighth** change — pipeline-free `VERSION` and `PROVEN_TARGETS` matching — is
**defensive hardening, not a defect fix**. It remains worthwhile: it is fork-free,
expresses exact membership more simply, and stays correct if the pins format ever
becomes multi-record. It corrected no exploitable production race. `grep -c` was
likewise cleanup — it consumes to EOF and can never receive SIGPIPE from an
early-exiting reader.

**The multi-line test-harness race was genuine.** Captured runner output *is*
multi-line, so `printf … | grep -q` assertions over it could fail on scheduling —
and one did, on hosted ARM. Those herestring conversions and the large multi-line
matcher control remain valid and load-bearing.

### Version guidance — skip 1.6.0 and 1.6.1

| Version | State |
|---|---|
| `bws-v1.6.0` | Published, immutable, **DEPRECATED and unsafe** — carries the seven defects |
| `bws-v1.6.1` | Published, immutable, **runtime-safe but SUPERSEDED** — its record overstates defect 8 |
| `bws-v1.6.2` | **This release** — corrected record, same safe runtime |

Consumers move **directly from `1.5.3` to verified `1.6.2`**, skipping both.
Existing 1.6.1 users need **no emergency rollback**: the runtime is unchanged
between 1.6.1 and 1.6.2 apart from comment corrections.

### Upstream bridged binary

| | |
|---|---|
| Upstream action | `bitwarden/sm-action` |
| Upstream release | **v3.0.1** |
| Upstream source commit | `1238aae8fc64b212641190a9227c8a734ab1a793` |

The action is **not** referenced as a `uses:` step. `scripts/bws/sm-action-run.sh`
downloads the native binary itself and verifies it against the digests committed
in `scripts/bws/sm-action.pins` **before** the file is made executable. No
source-build fallback; `SM_ACTION_VERSION` is unset.

### Pinned targets and digests

| Target triple | SHA-256 | Status |
|---|---|---|
| `aarch64-apple-darwin` | `a426480977db65e7ae0d50c5e0ba70508ff15bb1fc803a9b9048e5ccda8d1b73` | **PROVEN** — canary `macos-latest` |
| `x86_64-unknown-linux-gnu` | `fa998e9db775d5c7bdbc0fd8840ac6474a8348cdc989176c5ce24c3d09045752` | **PROVEN** — canary `ubuntu-latest` |
| `aarch64-unknown-linux-gnu` | `35dde396e46be03c2b8f711d8ea4c3c75a3b42ab6681a260d614b17fca726989` | **PROVEN** — canary `ubuntu-24.04-arm` |
| `x86_64-apple-darwin` | `9dfeab4d83b0347f9b5a04e8ca57f816c390b0f1c58a3d3bd7919ebfd3ab1124` | UNPROVEN — pinned, no Intel-Mac canary |
| `aarch64-pc-windows-msvc.exe` | `be716878c305707b7141e9581cdbf292c785f3aa3f7fbb42ac9c5e5460c09dba` | UNPROVEN — pinned, no canary; the runner is POSIX bash |
| `x86_64-pc-windows-msvc.exe` | `ae9cf1f9c400200cf889f17a44d7b3c9c525b9f462c0acd3cda76efab74e0174` | UNPROVEN — pinned, no canary; the runner is POSIX bash |

**Platform matrix.** Only the three PROVEN tuples are supported. An UNPROVEN
target is **refused at runtime** unless `SM_ACTION_ALLOW_UNPROVEN=1` is set
explicitly, and that override announces itself on stderr. A missing, empty, or
duplicated `PROVEN_TARGETS` declaration also refuses, before any network access.

### Loader identity and schema state

This release ships the **`sm-action-v1`** bridge: a generated composite action
passing `INPUT_ACCESS_TOKEN` and `INPUT_SECRETS` through the environment to the
verified binary, which performs its own masking and `GITHUB_ENV` export. The
data-only `secrets.map` schema belongs to the *proposed* `bwsm-cli-v1` loader
(`secrets.bwsm-ci-loader@1`) and is **not** part of 1.6.x — **no map schema
version applies to this release**.

### Migration

```text
bump scripts/.blessed-scripts-version to bws-v1.6.2
make sync-scripts
make verify-scripts
refresh the generated wrapper, review the diff, run repo checks, merge
```

Consumers on 1.5.3 move **directly** to 1.6.2. Any consumer that pinned 1.6.0 or
1.6.1 should move to 1.6.2 at the next opportunity — urgently for 1.6.0, routinely
for 1.6.1.

### Rollback and fallback

Rolling back from 1.6.2 lands on **1.5.3**, not 1.6.0 or 1.6.1: 1.6.0 is
deprecated and carries the seven defects, and 1.6.1's record is inaccurate. Note
that 1.5.3 predates the digest-verifying bridge and is **not** a valid
Darwin-arm64 path — it is the `sm-action` `uses:` form that fails under Node 24.
If a macOS release cannot wait, the temporary option remains the **consumer-only,
time-bounded** full-SHA pin
`bitwarden/sm-action@14f92f1d294ae3c2b6a3845d389cd2c318b0dfd8 # v2.2.0`, which
must never become generator output and must carry an owner, reason, affected
repos, review-by date, and removal condition.

### Known follow-up — not fixed here

The runner's whitespace normalisation of `PROVEN_TARGETS` is byte-quadratic
(≈54 s on a 377 KB value). Harmless for the committed ~80-byte production value;
recorded because it surfaced while building an oversized test fixture. No
oversized `PROVEN_TARGETS` fixture ships, because the failure it would have
demonstrated cannot occur for single-line input.

## [1.6.1] — 2026-07-30 — PUBLISHED, SUPERSEDED BY 1.6.2

> [!CAUTION]
> **Published, immutable, SUPERSEDED for record accuracy — prefer `bws-v1.6.2`.**
> **The 1.6.1 runtime is safe.** No part of the shipped loader is withdrawn and
> existing 1.6.1 users need **no emergency rollback**. What is wrong is the
> record below, which counts **eight** post-publication defects. The correct
> disposition is **seven defects plus one defensive hardening**: pipeline-free
> `PROVEN_TARGETS` / `VERSION` matching fixed no exploitable race, because both
> values are single-line by construction and `grep -q` cannot exit part-way
> through a line. The multi-line **test-harness** race was genuine. The tag and
> its assets are **untouched**; 1.6.1 is **superseded, not replaced**. Everything
> below this block is the historical record of what 1.6.1 actually shipped,
> byte-identical to `bws-v1.6.1:scripts/bws/CHANGELOG.md`. Post-publication
> corrections live **only** under [1.6.2].

Corrective release. **1.6.0 was published** as an immutable tag
(`bws-v1.6.0` → `8e86f394f96f9f8c02bc929368c624a276e42976`) before these defects
were found. Its tag and assets are **left untouched** — that is what immutable
means, and rewriting them would defeat the write-once property this category
exists to provide. 1.6.0 is **superseded**: consumers should adopt 1.6.1 and
skip it.

**Eight** findings from post-publication review, confirmed against the tagged source:

1. **`PROVEN_TARGETS` failed OPEN.** The `[ -n "$proven" ] &&` guard meant a
   missing or blank declaration silently disabled the unproven-platform gate
   entirely — the edit most likely to happen by accident was also the edit that
   removed the protection, while the support matrix still read as enforced.
   Absent, empty, or whitespace-only now means NO target is proven.
   `SM_ACTION_ALLOW_UNPROVEN=1` still overrides, but announces itself on stderr.

2. **bash 3.2 break, on the platform this bridge exists to support.**
   `${_bad,,}` is bash 4.0+; macOS ships 3.2.57 as `/bin/bash`. The
   option-conflict guard raised `bad substitution` instead of its message, and
   where bash 4 did run it, it named `--rotate_token` — a flag that does not
   exist. Replaced with an explicit variable-to-flag map.

3. **The documentation still taught the defect.** `README.md` and
   `CENTRALIZED-SECRETS.md` carried copyable `uses: bitwarden/sm-action@v2`
   examples. Fixing the emitter while the docs teach the old shape leaves the
   reintroduction path open. Both now lead with
   `uses: ./.github/actions/load-secrets`; the one retained historical example
   is labelled unsafe and noncanonical.

4. **VERSION reached the download URL unvalidated.** The digest check governs
   what EXECUTES, not where the request GOES, so a value carrying `/`, `?`, `#`,
   or whitespace could retarget the fetch while the digest check stayed happy to
   refuse whatever came back. VERSION must now match `^[0-9]+\.[0-9]+\.[0-9]+$`
   and be declared exactly once, rejected before `curl` is invoked.

5. **The accepted proposal contradicted master.**
   `standards/secrets/references/bwsm-ci-loader-migration.md` said the bridge
   must not become generator output, while the merged generator emits one.
   Section 5 now separates the three mechanisms: the proposed `bwsm-cli-v1`
   loader, the `sm-action-v1` generator bridge, and the v2.2.0 consumer-only
   emergency pin.

6. **`PROVEN_TARGETS` was read first-wins.** `sed … | head -1` resolved two
   disagreeing declarations by position, so a stale line still naming the current
   target silently overrode a later line that deliberately removed it — while the
   file read as though the target had been dropped. Ambiguity in a trust anchor
   is a malformed file, not something to resolve by position; it now fails closed.

7. **Duplicate target rows were also first-wins.** The same defect in the digest
   lookup: `awk … | head -1` meant two rows for one triple resolved by position,
   so a stale digest could silently win over the corrected one. Duplicate target
   rows are now rejected.

8. **The `PROVEN_TARGETS` membership test was a pipeline.** The match was
   `printf ' %s ' "$proven" | grep -q " $triple "`, under `set -o pipefail`.
   `grep -q` exits on its first match; the producer can then take SIGPIPE (141);
   `pipefail` reports that as the pipeline's status; the `elif` evaluates FALSE —
   and a target that **is** proven falls through and is refused as UNPROVEN.

   That is worse than a wrong answer: it depends on scheduling, so it passes
   locally and fails on a loaded hosted runner, and the diagnostic blames the
   pins file rather than the shell. Replaced with parameter expansion plus
   `[[ … == *" $triple "* ]]` — no fork, no pipe, no signal, and bash-3.2 safe.
   The redundant `| head -1` on `VERSION` went with it: the exactly-one count
   check above already guarantees a single declaration, so the pipe added only an
   early-exiting consumer.

Nothing here changes the published 1.6.0 bytes. The set-hash and archive of
`bws-v1.6.0` remain exactly as verified at publication.

### Consumers must skip 1.6.0

`bws-v1.6.0` is published, immutable, and **deprecated**. Adopt **1.5.3 → 1.6.1**
directly. Do not pin 1.6.0; its tag and assets are retained only for provenance.

### Upstream bridged binary

| | |
|---|---|
| Upstream action | `bitwarden/sm-action` |
| Upstream release | **v3.0.1** |
| Upstream source commit | `1238aae8fc64b212641190a9227c8a734ab1a793` |

The action is **not** referenced as a `uses:` step. `scripts/bws/sm-action-run.sh`
downloads the native binary itself and verifies it against the digests committed
in `scripts/bws/sm-action.pins` **before** the file is made executable. There is
no source-build fallback, and `SM_ACTION_VERSION` is unset so an earlier step
cannot redirect the download.

### Pinned targets and digests

| Target triple | SHA-256 | Status |
|---|---|---|
| `aarch64-apple-darwin` | `a426480977db65e7ae0d50c5e0ba70508ff15bb1fc803a9b9048e5ccda8d1b73` | **PROVEN** — canary `macos-latest` |
| `x86_64-unknown-linux-gnu` | `fa998e9db775d5c7bdbc0fd8840ac6474a8348cdc989176c5ce24c3d09045752` | **PROVEN** — canary `ubuntu-latest` |
| `aarch64-unknown-linux-gnu` | `35dde396e46be03c2b8f711d8ea4c3c75a3b42ab6681a260d614b17fca726989` | **PROVEN** — canary `ubuntu-24.04-arm` |
| `x86_64-apple-darwin` | `9dfeab4d83b0347f9b5a04e8ca57f816c390b0f1c58a3d3bd7919ebfd3ab1124` | UNPROVEN — pinned, no Intel-Mac canary |
| `aarch64-pc-windows-msvc.exe` | `be716878c305707b7141e9581cdbf292c785f3aa3f7fbb42ac9c5e5460c09dba` | UNPROVEN — pinned, no canary; the runner is POSIX bash |
| `x86_64-pc-windows-msvc.exe` | `ae9cf1f9c400200cf889f17a44d7b3c9c525b9f462c0acd3cda76efab74e0174` | UNPROVEN — pinned, no canary; the runner is POSIX bash |

**Platform matrix.** Only the three PROVEN tuples are supported. An UNPROVEN
target is **refused at runtime** unless `SM_ACTION_ALLOW_UNPROVEN=1` is set
explicitly, and that override announces itself on stderr. As of 1.6.1 a missing,
empty, or duplicated `PROVEN_TARGETS` declaration also refuses — before any
network access.

### Loader identity and schema state

This release ships the **`sm-action-v1`** bridge: a generated composite action
that passes `INPUT_ACCESS_TOKEN` and `INPUT_SECRETS` through the environment to
the verified binary, which performs its own masking and `GITHUB_ENV` export. The
data-only `secrets.map` schema belongs to the *proposed* `bwsm-cli-v1` loader
(`secrets.bwsm-ci-loader@1`) and is **not** part of 1.6.x — **no map schema
version applies to this release**.

### Migration

```text
bump scripts/.blessed-scripts-version to bws-v1.6.1
make sync-scripts
make verify-scripts
```

Then update the consumer's `.github/actions/load-secrets/action.yml` — and note
that **which way is safe depends on the wrapper that repo already has.**
`bootstrap.sh --scaffold` writes that file **only when it is absent**, and 1.6.x
ships no refresh mode, so on an existing consumer "regenerate" can only mean
*delete and re-scaffold*. The 1.6.x template is **profileless**: one
`access_token` input and one flat `INPUT_SECRETS` block. It cannot render a
`profile` input at all. Re-scaffolding is therefore not a refresh for every
consumer — for some it is a silent downgrade.

**Profile-aware consumers must NOT regenerate from the 1.6.x template.** A repo
whose loader takes the `profile` input of `secrets.bwsm-authority-domains@1`
would have its profile-aware wrapper replaced by a single-profile one, collapsing
every named privileged profile — and the authority-domain boundary those profiles
carry — into the default set. **Convert in place instead.** For each
`uses: bitwarden/sm-action@…` step already in that wrapper, change only how that
one step executes:

- drop the `uses:` line; add `shell: bash` and
  `run: bash "$GITHUB_WORKSPACE/scripts/bws/sm-action-run.sh"`;
- move that step's `with:` block to `env:`, renaming each input to its
  `INPUT_<UPPERCASE>` form — `access_token` → `INPUT_ACCESS_TOKEN`,
  `secrets` → `INPUT_SECRETS`, and likewise for any `base_url`, `identity_url`,
  `api_url`, or `set_env` the step sets.

Everything else stays exactly as it is: every `profile` input, every `if:`
condition, every opt-in, and every `<uuid> > KEY` mapping. Then run that repo's
**profile-isolation and mutation tests** — a conversion that quietly widened a
profile, or dropped a condition, still passes a happy-path run and fails only
those.

**Profileless consumers may regenerate, on a separate and narrower path.** It is
safe only where the wrapper takes no `profile` input *and* carries no hand edit:
delete `.github/actions/load-secrets/action.yml`, re-run
`bootstrap.sh --scaffold`, then review the diff. A fresh scaffold emits the
`00000000-0000-0000-0000-000000000000` placeholder for every per-project key —
only `shared`-marked keys come back with real UUIDs — so a full `bootstrap.sh`
run against BWS is required to refill them, and no placeholder may survive into
the merge. Where either condition fails, convert in place by the steps above:
re-scaffolding discards whatever was hand-added, and it does so silently.

Consumers on 1.5.3 move **directly** to 1.6.1. Any consumer that pinned 1.6.0 —
none are known — should move to 1.6.1 at the next opportunity.

### Rollback and fallback

Rolling back from 1.6.1 lands on **1.5.3**, not 1.6.0: 1.6.0 is deprecated and
carries the eight defects above. Note that 1.5.3 predates the digest-verifying
bridge and is **not** a valid Darwin-arm64 path — it is the `sm-action` `uses:`
form that fails under Node 24. If a macOS release cannot wait, the temporary
option remains the **consumer-only, time-bounded** full-SHA pin
`bitwarden/sm-action@14f92f1d294ae3c2b6a3845d389cd2c318b0dfd8 # v2.2.0`, which
must never become generator output and must carry an owner, reason, affected
repos, review-by date, and removal condition.

## [1.6.0] — 2026-07-29 — PUBLISHED, DEPRECATED, SUPERSEDED — USE 1.6.2

> [!CAUTION]
> **Published, immutable, DEPRECATED — do not newly adopt `bws-v1.6.0`.**
> **Seven** defects found after publication are corrected in **1.6.1**, whose
> own record is in turn corrected by **1.6.2** — adopt 1.6.2, not 1.6.1.
> (1.6.1 counted eight; the eighth was defensive hardening, not a defect.)
> The tag and its assets are **untouched** and remain exactly as published;
> 1.6.0 is **superseded, not replaced**. Everything below this block is the
> historical record of what 1.6.0 actually shipped, byte-identical to
> `bws-v1.6.0:scripts/bws/CHANGELOG.md`. Post-publication corrections live
> **only** under [1.6.1] and [1.6.2].

- **Security: the BWS loader no longer executes an unverified binary.** The
  loader called `bitwarden/sm-action`, pinned to a commit SHA. That pin was
  cosplay: the action's `index.js` is a ~6KB downloader that fetches a release
  asset, `chmod 0755`'s it, and `execSync`'s it — with **no digest check and no
  signature**. The commit pin covered the downloader; the bytes that actually run
  were unpinned and mutable, since a release asset can be deleted and re-uploaded
  under the same tag.

  Two further problems in the same file made it worse than a missing digest:
  - `getVersion()` honours the **`SM_ACTION_VERSION` environment variable** and
    interpolates it into the download URL, so any earlier step or job-level env
    could redirect which binary was fetched and executed;
  - on download failure it silently fell back to `rustup target add` +
    `cargo build --release`, compiling and running code from the action tree.

  New `sm-action-run.sh` + `sm-action.pins` fetch the binary directly and verify
  it against committed per-target SHA-256 digests (the authoritative values
  GitHub reports for the release assets) **before** the file is ever made
  executable. `SM_ACTION_VERSION` is unset; a mismatch is fatal; there is no
  source-build fallback. Caller contract is unchanged — the native binary still
  does its own masking and `GITHUB_ENV` export.

- **This also unblocks Node 24 / macOS ARM64.** sm-action v2's NAPI build could
  not resolve `@bitwarden/sdk-napi-darwin-arm64` under Node 24, which crashed
  macOS runners. v3 ships a Rust binary and fixes it — this change lets us adopt
  v3 without inheriting its unverified-execution problem.

- **Fix: the runner now materializes the upstream action's INPUT defaults.**
  `sm-action-run.sh` replaces `uses: bitwarden/sm-action@...`, and GitHub
  materializes an action's declared input defaults **only** for `uses:` steps —
  a direct invocation gets none. `set_env` defaults to `"true"` upstream, so the
  binary fetched the secret, verified it, and exported **nothing**: the canary
  failed with "no secret was exported", and every consumer of this loader would
  have silently received no secrets.

  All four defaults the pinned `action.yml` declares are now reproduced
  (`base_url`, `identity_url`, `api_url`, `set_env`), applied only when unset so
  an explicit `INPUT_SET_ENV=false` is preserved. Fixed in the runner rather than
  at each caller: the runner is the boundary that replaced `uses:`, so it owns
  that compatibility contract — three call sites each remembering to set it is
  the same bug waiting for a fourth caller.

- **Proof, not assertion.** `tests/test-bws-sm-action-pin.sh` pairs every
  guarantee with a negative control, and asserts a mismatched binary is **never
  executed** (refusing *after* running it would be no refusal). A daily
  `bws-loader-canary` workflow re-proves the live published asset still matches
  the pin on macOS ARM64, Linux x86_64, and Linux ARM64 — because "upstream has
  not replaced the asset" is a claim that decays and must be re-checked on a clock.

## [1.5.3] — 2026-07-23

- **Fix: finalize secret-scan false positive on the vendored bws test fixtures.**
  The pre-finalize scan flagged the literal `BEGIN PRIVATE KEY` markers that the
  test suite embeds (synthetic body `ZZ`) to exercise the scanner — so **any** repo
  that vendors the bws category could never `finalize` a rotation. Fixed WITHOUT
  weakening the scan (a directory-wide skip of `scripts/bws/`/`scripts/signing/`
  was rejected — a manifest proves byte integrity, not secret absence, so it would
  create a real blind spot):
  - `authority-domains-test.sh` now builds the fake marker at runtime from split
    strings, so the **shipped test source no longer contains a complete marker**
    (so the allowlist never needs to grow for v1.5.3+);
  - the exemption is a **WHOLE-FILE identity** check — private-key class ONLY, at the
    exact path `scripts/bws/authority-domains-test.sh` ONLY, and ONLY when the entire
    file's SHA-256 is one of the three reviewed released hashes (from each release's
    `MANIFEST.sha256` `authority-domains-test.sh` row: `bws-v1.5.0` `6582e383…`,
    `bws-v1.5.1` `cfbe2293…`, `bws-v1.5.2` `663d633f…`).
  Because the check is over the entire file, **any** byte change removes the
  exemption automatically — this **cannot fail open** (an earlier line-substring
  draft could: a line bearing the fixture AND a second real marker would be skipped
  whole). A changed body, a real PEM in that file, a second marker on the same or a
  different line, a one-byte change, a marker anywhere else under `scripts/bws` /
  `scripts/signing`, or an untracked/staged/committed-then-deleted PEM elsewhere all
  still fail. Suite now **88 checks** (9 exemption cases incl. both fail-open
  same-line/different-line regressions and the whole-file identity via worktree AND
  history paths).

## [1.5.2] — 2026-07-22

- **Fix: smoke proof no longer compares `workflowName` to the executable YAML
  `name:`.** When the smoke workflow is registered on the default branch as a
  non-executable shim and executed from `--ref` `AUTH_BRANCH` (e.g. `release`),
  GitHub's `run.workflowName` reports the **shim's** YAML name. Comparing that
  string to the release-branch workflow name rejected otherwise successful
  proofs (observed on DocSort run `29975302316`).
- **Authoritative smoke identity** is now taken from the Actions REST run object
  for the exact `smoke_run_id`:
  - `path` must be `.github/workflows/authority-domain-smoke.yml`
  - `event` must be `workflow_dispatch`
  - `display_title` must equal the correlation `authority-smoke:<rid>:<new>`
  - `head_branch` must equal `AUTH_BRANCH`
  - `head_sha` must equal the trust-verified commit
  - `status=completed` and `conclusion=success`
  - jobs list must include a completed successful job named `sign-verify`
- When `smoke_run_id` is already persisted, resume **polls/revalidates that run
  only** and never re-dispatches.
- Smoke-workflow **template is unchanged** (existing successful runs stay
  compatible).
- Regressions: shim `workflowName` ≠ executable YAML name passes; wrong path /
  title / event / branch / SHA fail; missing/failed/cancelled/skipped
  `sign-verify` fail; resume with persisted `smoke_run_id` performs no dispatch.
- Suite now **79 checks**.

## [1.5.1] — 2026-07-22

- **SECURITY (script injection in the smoke workflow template).** The rendered
  `authority-domain-smoke.yml` interpolated a caller-controlled `workflow_dispatch`
  input directly into an inline shell script (`KID="${{ inputs.new_key_id }}"`),
  and that step ran **after** the release signing key was loaded — a command-
  injection sink reachable by anyone who can dispatch the workflow. Fixed at the
  shared source (`templates/authority-domain-smoke.yml.tmpl`):
  - dispatch inputs enter **only** as job-level `env` (`ROTATION_ID` / `NEW_KEY_ID`);
    **no `${{ inputs.* }}` appears in any `run:` block**;
  - a **secret-free validation step runs FIRST**, before checkout and before
    `load-secrets`, rejecting anything that fails the `rotation_id` /`new_key_id`
    grammar or contains `..` — so a malicious input never reaches the key-loading
    step;
  - the signing step reads the validated value from `$NEW_KEY_ID`.
  Regressions prove quotes, `;`, `$()`, backticks, whitespace, newlines, `/`, and
  `..` all fail before `load-secrets`, and that no `inputs` expression survives in a
  `run:` block.
- **`workflow_dispatch` default-branch registration.** GitHub only delivers
  `workflow_dispatch` events for a workflow present on the repository **default
  branch**. Preflight now discovers the default branch and requires the smoke
  workflow **path** there (a non-executable registration shim) in addition to the
  **executable** workflow on `AUTH_BRANCH` (still byte-verified at the trust commit).
  The two are **not** required byte-equal. Regressions: missing default-branch
  registration fails; missing `AUTH_BRANCH` executable fails; shim + executable
  passes; a `authority-registration:`-titled run can never satisfy the
  `authority-smoke:` correlation. Reusable-tool follow-up: blessed-cicd#198.
- Suite now **64 checks**.

## [1.5.0] — 2026-07-21
- **Authority-domain rotation tool** (`authority-domains.sh`) for
  `secrets.bwsm-authority-domains@1`: `plan` · `rotate-signing-key` · `audit` ·
  `resume`. A rotation is a **resumable, fail-closed, multi-checkpoint transaction
  whose boundaries are REMOTE state** (not the local worktree), because trust
  distribution + activation can't be atomic with a CI proof:
  `prepare → trust-prepare (STOP) → trust-deploy (verify remote ref) → store →
  smoke (dispatch + verify the EXACT run) → activate-prepare (STOP) →
  activate-deploy (verify remote ref) → finalize`. It REUSES the existing project +
  machine account + Environment + `BWS_ACCESS_TOKEN` (rotation ≠ provisioning);
  discovers topology from `blessed.yml`; delegates key generation to the sibling
  `signing` category (which must be vendored alongside). Secret-safe: no private key
  or token in argv/logs/state/git (`set +x`/`set +a`/`umask 077`); BWS auth via
  `BWS_ACCESS_TOKEN` env, never `-t`; atomic verified state writes fail closed; the
  pre-finalize scan checks BOTH the working tree AND the staged index; key_ids are
  path-validated and never reused; the state dir uses an opaque id. `plan` is
  genuinely read-only (creates no state). `--reason compromised` → old key
  `revoked`; `scheduled` → `verify-only`. One explicit web-vault checkpoint stores
  the multiline PEM (the CLI takes VALUE positionally). Ships
  `authority-domains-test.sh` (46 checks incl. a stateful fake-GitHub integration
  test of the checkpoint flow, plus a clean-install test that extracts the exact
  release tarball layout). The smoke run is CORRELATED (unique run-name +
  headSha == the verified trust commit); trust-deploy verifies BOTH key states
  (rejects a both-active remote store); an in-progress rotation is IMMUTABLE
  (reason/params can't change on a second invocation); resume ids are path-safe;
  preflight verifies the vendored bws version pin + MANIFEST + the installed smoke
  workflow. `install-smoke-workflow` renders the workflow from blessed.yml
  (generic secret name). v1.5.0 scope is the PRODUCER trust store only
  (multi-repo distribution tracked in #198). Smoke template: `scripts/bws/templates/authority-domain-smoke.yml.tmpl` (installed via `authority-domains.sh install-smoke-workflow`).
  Read-only auditor → #197; this tool → #198. `provision` is still a guided stub.
  Both #197 and #198 gate the standard (proposal → standard).
  - **Proof-integrity hardening:** activation re-verifies the FULL trust store
    (new active + exact pubkey bytes + old demoted) at the same immutable
    activation commit, not just `release.yml`; the smoke proof is bound to the
    byte-exact reviewed workflow at the verified trust commit and to the sibling
    `signing` category's version/tag/MANIFEST.
  - **Self-contained distribution:** integrity is verified by
    `verify-category-manifest.sh`, which SHIPS INSIDE the bws category, so a
    consumer installed from the tarball alone (no source-tree `scripts/manifest.sh`)
    can run preflight and the smoke workflow. The rendered smoke workflow calls
    `scripts/bws/verify-category-manifest.sh scripts/signing` before loading the key.
  - **Complete secret scan:** the pre-finalize scan now also covers
    untracked-but-not-ignored worktree files and every blob introduced since the
    rotation's starting commit (a PEM committed then deleted still trips it),
    excluding the protected state dir; finalize fails if HEAD is not a descendant
    of the recorded starting commit.
  - **Pin-file migration:** preflight selects `scripts/.blessed-scripts-version`
    and falls back to the legacy `scripts/.bws-scripts-version` (canonical wins).

## [1.4.1] — 2026-07-19
- **Metadata:** add `API_VERSION` (the category's stable interface version) for the
  new script-category catalog (`scripts/catalog.yml`). No behavior change; ships the
  new file in the tarball so the released payload matches the repo.

## [1.4.0] — 2026-06-29
- **Multiple shared projects** (#126). A repo can now resolve `shared` keys from
  more than one BWS project — least-privilege *scoped* sharing (a token visible to
  N specific repos) alongside the portfolio-wide `_shared-ci`.
  - `.bws-secrets-list`: new `shared:PROJECT` marker, e.g.
    `PROOFGLASS_ACTION_TOKEN  shared:proofglass-consumers`. Bare `shared` is
    unchanged (== `_shared-ci`); project name/uuid matches `^[A-Za-z0-9._-]+$`.
  - `load.sh`: merges every referenced shared project — per-key named projects,
    the bare-`shared` default, **and** a new `BWS_SHARED_PROJECT_IDS` (space/comma
    list). `BWS_SHARED_PROJECT_ID` still works as the single-value default.
  - `bootstrap.sh`: still skips per-project create for shared keys; status lines
    and the machine-account read-grant reminder now name the correct project(s).
  - `_lib.sh`: parser exposes a fifth array, `_BWS_PARSED_SHARED_PROJECT`.
  - Back-compat: bare `shared`, unset `BWS_SHARED_PROJECT_ID`, and the default
    static-site set are unchanged. The named/list syntax is strictly opt-in.
  - See `docs/shared-secrets.md`.

## [1.3.0] — 2026-06-23
- **Helptext:** Cloudflare-Worker Access onboarding fixes surfaced while wiring the
  `porta.codes` Worker consoles (`review.porta.codes` / `release.porta.codes`):
  - `cloudflare_token_worker` — add `Account → Access: Apps and Policies:Edit` to
    the listed permissions. A Worker that Terraform-manages a
    `cloudflare_zero_trust_access_application` needs it; without it `terraform apply`
    403s creating the Access app. The existing Workers Scripts / KV / D1 /
    Account-Settings perms are unchanged.
  - `github_app_private_key` — require storing the value **base64-encoded,
    single-line** (`base64 < app.pem | tr -d '\n'`) so it has no raw control
    characters. A multi-line PEM breaks `load.sh`'s jq merge (issue #69), dropping
    ALL secrets; the consumer's Worker base64-decodes it back to PEM at runtime.
    The raw `.pem` remains only the source file and must not be stored directly.
  - **New type** `cloudflare_access_aud` — the Cloudflare Access Application
    Audience (AUD) tag. NOT minted by hand: auto-generated when the Access app is
    created by `terraform apply`, distinct per app. Get it with
    `terraform output -raw access_application_aud` (prefix `TF_WORKSPACE=production`
    if the state is workspaced). Two-phase — leave empty on the first bootstrap
    pass and fill after the first apply.
  - **New type** `cloudflare_access_team_domain` — the bare
    `<team>.cloudflareaccess.com` Zero Trust team domain (Zero Trust → Settings);
    same across all apps in the account.
  Also updates the supported-types comment block and the `CENTRALIZED-SECRETS.md`
  table. Additive only (new `case` branches before the `*)` default, edits to two
  existing branches); no existing behavior changed.

## [1.2.0] — 2026-06-23
- **Feature:** four new `.bws-secrets-list` helptext types for Cloudflare-Worker
  apps that ship a GitHub App + a session signing key (first consumers:
  `review.porta.codes` / `release.porta.codes`):
  - `cloudflare_token_worker` — USER-owned token scoped for a **Worker** deploy
    (Workers Scripts / KV / D1 / Account Settings), distinct from the static-site
    zone/DNS token. Closes #77.
  - `github_app_id` — the App's numeric App ID.
  - `github_app_private_key` — the App private key (PEM). Explicitly warns the
    value is multi-line and the single-line `read -rs` prompt would truncate it,
    steering the operator to env-var capture or `--no-secret-values` web-UI paste
    (same class of footgun as #69).
  - `hmac_key` — a random signing key via `openssl rand -base64 48`.
  Also updates the supported-types comment block and the `CENTRALIZED-SECRETS.md`
  table. Additive only (new `case` branches before the `*)` default); no existing
  behavior changed.

## [1.1.1] — 2026-06-16
- **Docs:** add `scripts/bws/INSTALL.md`, the release-tarball install and update
  guide for consumer repos. It documents the canonical `scripts/bws/` install
  path, version pinning via `scripts/.bws-scripts-version`, manifest verification,
  Makefile wrapper targets, the safer `--scaffold --no-secret-values` bootstrap
  flow, and `.bws-secrets-list` guidance for non-static-site consumers.
- **Docs:** add a bootstrap-flag table defining `--scaffold` and
  `--no-secret-values` (and noting `--dry-run` / `--rotate-token`), a prerequisites
  pointer, and a cross-link to the consolidated new-repo runbook in
  `scripts/INSTALL.md`. Note that pinned version literals are examples.
- No runtime script changes; `MANIFEST.sha256` remains unchanged because it covers
  the shipped `.sh` runtime files.

## [1.1.0] — 2026-06-03
- **Feature:** new `google_service_account` helptext type for `.bws-secrets-list`.
  Rolling a Google Cloud service-account credential (the kind a Sheets / Drive /
  GCS data-pipeline needs) involves Console clicks across IAM & Admin, an
  API-library enable step, a Keys-tab JSON download, AND a per-resource share
  with the SA's email — none of it obvious without a runbook. The new type
  prints a 6-step procedure with direct links to the Console pages an operator
  hits (Service Accounts, Project Create, Sheets / Drive API library pages),
  the SA naming convention (`$APP_NAME-ci`), and the rotation pattern
  (multiple active JSON keys at once).

  Step 6 of the runbook explicitly calls out that the interactive prompt
  (`read -rs value`) is **single-line** — pretty-printed JSON pasted directly
  into the prompt silently captures only `{` and bootstrap reports "created"
  against a broken secret value. The operator is steered to one of two
  multi-line-safe paths:

  (a) capture into an env var, then re-run:

  ```
  export GOOGLE_SHEETS_SERVICE_ACCOUNT_JSON="$(cat ~/Downloads/<project>-XXXX.json)"
  make bws-bootstrap   # re-run; reads from $GOOGLE_SHEETS_SERVICE_ACCOUNT_JSON
  ```

  (b) `--no-secret-values` mode: skip the prompt entirely, paste pretty JSON
  via the Bitwarden vault web UI, then re-run without the flag to fill the
  load-secrets action.yml UUID.

  Consumers opt in by adding `type:google_service_account` to the secret's
  line in `.bws-secrets-list`, e.g.:

  ```
  GOOGLE_SHEETS_SERVICE_ACCOUNT_JSON? type:google_service_account
  ```

  No backward-compatibility break — the existing 9 type cases are unchanged,
  the by-key fallback (Layer 2) and generic pointer (Layer 3) keep working
  for keys without a type. First consumer is the kiosk repo
  (`AzimuthSuborbital/kiosk.broadwatercenter.com`), whose `.bws-secrets-list`
  declares `GOOGLE_SHEETS_SERVICE_ACCOUNT_JSON?` for the planned tenant-data
  pipeline (kiosk #5).

## [1.0.5] — 2026-06-03
- **Defensive:** `load.sh` now `unset AWS_PROFILE` right after the BWS keys
  are exported. A leftover `AWS_PROFILE` (inherited from the operator's
  shell — e.g. an aws-plugin default — or set in a hand-authored consumer
  `.env-sample`) causes the Terraform AWS provider to try to look up that
  profile in `~/.aws/config` before honoring the BWS-loaded
  `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY`, surfacing as
  `Error: failed to get shared config profile, <name>` on
  `terraform init` for any profile the operator never wrote to local
  shared config (typically the CI deploy user, `<APP_NAME>-ci`). Sourcing
  `load.sh` is the operator's signal that BWS env-credentials are now the
  source of truth, so AWS_PROFILE is both unnecessary and actively
  harmful at that point. Admin tasks that genuinely need a profile (e.g.
  `ruam.sh --new`) should set `AWS_PROFILE=<admin>` *inline* at the
  invocation, not in the shell or `.env-sample`.
- Documents the policy in `CENTRALIZED-SECRETS.md` (new
  "Local environment hygiene" section).

## [1.0.4] — 2026-05-31
- **Fix:** `load_keys_override` returned 1 (tripping the script's ERR trap)
  when a consumer repo had a `.bws-secrets-list` with NO keys marked
  `shared`. The function's last command was `$HAS_SHARED && info "..."`;
  when `HAS_SHARED=false` that short-circuited as `false && ...`, the
  function inherited that exit status, and `set -E` propagated the failure
  to the caller — surfacing as `ERROR: bootstrap.sh line 378 exit 1 / while
  running: $HAS_SHARED` on the next line (the `load_keys_override` call).
  Rewrote the conditional as `if $HAS_SHARED; then info "..."; fi`, which
  always returns 0. Regression introduced in 1.0.2 when shared-keys
  support landed; surfaces only when (a) `.bws-secrets-list` is present
  AND (b) none of its entries carry the `shared` marker. The no-file
  default path already had an explicit `return 0`, so portfolios that use
  defaults were never affected.
- No functional changes elsewhere; the only file in this release diff is
  `bootstrap.sh` (plus the matching `MANIFEST.sha256` and `VERSION` bump).

## [1.0.3] — 2026-05-28
- **Fix (zsh):** `_lib.sh` parsed the post-key metadata fields with
  `for field in $rest`, which relies on word-splitting. bash word-splits
  unquoted expansions; **zsh does not**, so when `load.sh` is *sourced into the
  operator's zsh shell* a line like `KEY shared type:x` arrived as a single
  token and was wrongly rejected (`unknown field after key … shared\ type:x`).
  Re-tokenized with pure parameter expansion so it behaves identically under
  bash and zsh. Regression introduced in 1.0.2; CI was never affected (CI loads
  via `sm-action`/`action.yml`, not `load.sh`).
- Added `tests/test-bws-parser-zsh-smoke.sh` (run by `make test` when zsh is
  present) so the sourced-into-zsh path is covered going forward.
- `bootstrap.sh` helptext: the `cloudflare_token_user` mint instructions now
  include `Zone:Transform Rules:Edit`. The canonical `dns` workspace ships a
  security-headers ruleset (`http_response_headers_transform`), which fails with
  Cloudflare auth error 10000 if the token only has Settings/DNS/Page-Rules.
  Same correction swept across every canonical Cloudflare-token permission list:
  `CENTRALIZED-SECRETS.md` (+ a 10000 troubleshooting note), `README.md`,
  `docs/CLI - BWS-BOOTSTRAP.md`, `docs/migration-decouple-dns-trigger.md`, and
  `docs/migration-cloudflare-provider-3x-to-5x.md`.

## [1.0.2] — 2026-05-28
- Shared secrets via the `_shared-ci` BWS project (see `docs/shared-secrets.md`).
  A `.bws-secrets-list` entry may now carry a bare `shared` marker
  (`KEY[?] [shared] [type:VALUE]`, order-independent):
  - `_lib.sh`: parser accepts `shared` and exports the parallel
    `_BWS_PARSED_SHARED[]` array.
  - `bootstrap.sh`: shared keys are **not created** in the per-project (they
    live in `_shared-ci`), their `action.yml` UUID is **not rewritten**, the
    scaffold writes the canonical `_shared-ci` UUID for them, and the
    machine-account step reminds the operator to grant read on `_shared-ci`.
  - `load.sh`: when any key is `shared`, merges the `_shared-ci` project
    (`BWS_SHARED_PROJECT_ID`, default the canonical id) on top of the
    per-project secrets so shared keys resolve locally; shared values win on
    collision; non-fatal if the shared project can't be read.
  Rationale: `CLOUDFLARE_ACCOUNT_ID` and `BETTERUPTIME_API_TOKEN` are identical
  across every site and low-privilege, so they're rolled once centrally instead
  of duplicated per project. High-value creds (AWS, Cloudflare API token) stay
  per-project — see the "what may live here" bar in the doc.
- Default-path consistency (was inconsistent with the canonical template, which
  bakes the `_shared-ci` UUIDs): with **no** `.bws-secrets-list`, the static-site
  default set now treats `CLOUDFLARE_ACCOUNT_ID` + `BETTERUPTIME_API_TOKEN` as
  `shared` too — `bootstrap.sh` skips creating them per-project (via
  `DEFAULT_SHARED_KEYS`) and `load.sh` merges `_shared-ci`. Previously the default
  path created/loaded per-project copies while CI loaded the shared UUIDs.
- `load.sh`: `SLACK_WEBHOOK_URL` removed from `_BWS_DEFAULT_OPTIONAL` (now empty)
  and the header no longer says "Slack-optional" — the canonical default is the
  5-key set; Slack is `.bws-secrets-list` opt-in only (matches the template,
  README, bootstrap).
- Doc sweep of residual 6-secret/Slack-default references (README Path A/B + the
  `secrets:` example, `CENTRALIZED-SECRETS.md`).

## [1.0.1] — 2026-05-28
- `bootstrap.sh`: add a `cloudflare_account_id` helptext type (with a dashboard
  link to find the Account ID) and recognize `cloudflare_api_token` as an alias of
  `cloudflare_token_user`. Fixes the "Unknown type … falling back to by-key" warning
  and the missing Account-ID link surfaced during the bracketsnap.app secret roll.

## [1.0.0] — 2026-05-28
- Canonical home established in blessed-cicd under `scripts/bws/`: `bootstrap.sh`,
  `load.sh`, `_lib.sh`.
- De-stuttered from the legacy flat names (`bws-bootstrap.sh` / `load-bws-secrets.sh`
  / `_bws-secrets-list.sh`) — the folder namespaces them.
- 5-key default set (AWS×2, CLOUDFLARE×2, BETTERUPTIME); **SLACK_WEBHOOK_URL is not
  a default** — Slack flows through github-slack-router, not per-repo webhooks.
- Carries the bootstrap robustness fixes: ERR-trap diagnostics (#39) and the
  `extract_env_project_id` / `rewrite_env_file` regex alignment (#38).
- `.bws-secrets-list` is the single source of truth both `bootstrap.sh` (create)
  and `load.sh` (load/validate) consume.
