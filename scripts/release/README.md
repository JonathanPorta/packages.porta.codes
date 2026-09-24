# release — candidate assembly, validation & promotion

A first-class blessed script category (peer of `bws`/`ruam`/`signing`) that turns
an **explicit producer plan** into a deterministic, validated
`release-candidate.json` (`blessed/release-candidate/v1`). It owns candidate data;
it delegates **all cryptography** to the `signing` category through its CLI
(API v1) — it never sources `signing-lib.sh` and never calls `openssl`.

## Owns / does not own

**Owns (candidate):** explicit candidate-plan input, deterministic `release-candidate.json`,
stable key/array ordering, closed payload list, safe-basename checks, file sizes +
SHA-256, `SHA256SUMS`, generic provenance, schema + semantic-closure validation,
on-disk hash recompute, envelope validation, signing-API compatibility check.

**Owns (promotion):** admission of a candidate-ready event against the signed
candidate and the surface declaration, deterministic rendering of channel
pointers and download indexes, forward-only version ordering, and the promotion
PR state machine up to — but not including — publication.

**Does not own:** platform builds, filename→platform/install_kind inference, SBOM
generation, release-note composition, BWS access, GitHub Release/tag creation,
S3/R2 upload, promotion events. Those stay in the producer.

## Commands

```bash
# validate a producer plan
release/validate-plan.sh --plan candidate-plan.json

# assemble: verify referenced files, hash them, emit provenance + SHA256SUMS + manifest
release/build-candidate.sh --plan candidate-plan.json --candidate-dir dist \
  --output dist/release-candidate.json --builder "$GITHUB_RUN_ID"

# (sign the manifest separately) signing/sign.sh --input dist/release-candidate.json ...

# validate: schema + closure + on-disk recompute, and — with a trust store — the signature
release/validate-candidate.sh --candidate-dir dist \
  --trust-store release-trusted-keys.json --signing-dir scripts/signing
```

Promotion is three stages, and the separation is the point:

```bash
# 1. ADMIT — the trust boundary. Prints the admission_id on stdout.
AID=$(release/admit-candidate-ready.sh --event event.json --candidate-dir dist \
  --receipt release-receipt.json --attestation attestation.json \
  --receiver-repo ../site --receiver-base-sha "$BASE_SHA" \
  --surfaces-path release-surfaces.yaml \
  --renderer-config-path receiver-downloads-index-policy.json \
  --surface-id public-downloads --channel stable \
  --trust-store release-trusted-keys.json --signing-dir scripts/signing \
  --bundle-out bundle/)

# 2. RENDER — re-runs admission, then renders. All or nothing.
release/render-promotion.sh --bundle-dir bundle/ --receiver-repo ../site \
  --outdir rendered/ --signing-dir scripts/signing \
  --trust-store release-trusted-keys.json \
  --expected-admission-id "$AID" --expected-base-sha "$BASE_SHA" \
  --expected-surface-id public-downloads --expected-channel stable

# 3. APPLY — re-runs admission, re-renders, compares, then upserts one PR.
#    --surface-manifest is REQUIRED and takes the EXACT published manifest.json
#    bytes. See "Acquiring the surface manifest" below: apply re-checks their
#    digest against the publication attestation, so supplying the wrong bytes
#    is a refusal, not an accepted shortcut.
release/apply-promotion-pr.sh --bundle-dir bundle/ --receiver-repo ../site \
  --rendered rendered/ --pr-state pr-state.json \
  --surface-manifest published/manifest.json \
  --signing-dir scripts/signing \
  --trust-store release-trusted-keys.json \
  --expected-admission-id "$AID" --expected-base-sha "$BASE_SHA" \
  --expected-surface-id public-downloads --expected-channel stable \
  --base-ref main --publish --adapter release/adapters/gh-pr-adapter.sh
```

## Acquiring the surface manifest

`apply-promotion-pr.sh` needs the **exact bytes** published at
`<immutable prefix>/manifest.json` — the surface manifest
(`blessed/public-download-manifest/v1`), which is what a channel pointer's
`manifest_url` names. It is authored by the surface owner and is **not** the
producer's signed envelope; that stays published as `release-candidate.json`
with its own signature.

Supply the bytes the publisher actually wrote. In a receiver pipeline that is
the manifest the publish stage materialized and published, carried forward to
the promotion stage — for example as a job artifact. Fetching them back from
the published URL works equally well.

What must NOT be used is a bundled or repository fixture. The candidate bundle
does not contain this document, and a checked-in copy is not evidence of what
was published.

Whatever the route, apply does not trust the bytes it is handed:

1. it recomputes their digest and size and requires both to equal what the
   **publication attestation** recorded for that URL;
2. it validates them against `blessed/public-download-manifest/v1`;
3. it binds their content to the **admitted, signature-verified candidate** —
   release identity, the candidate digest they project, every asset identity,
   size, hash and canonical URL, and the release name, publication time and
   notes URL against the candidate and the Release receipt.

So a substituted or stale manifest is refused before any branch, commit or
pointer moves. Presence at a URL is not acceptance.

**Ordering note for adopters.** `--surface-manifest` is mandatory, so a caller
must acquire the bytes *and* pass the argument in the same change that pins this
version. A receiver cannot pass the argument to an earlier applier, which
rejects unknown flags, and this applier refuses a caller that omits it — so the
pin bump and the caller wiring land together or the promotion stops at
`STATE unattested`.

## The trust root never travels with the artifact

The candidate trust store is supplied to **every** stage independently of the
bundle. A store carried inside the bundle would be caller-controlled, which
makes signature verification circular: anyone supplying candidate, signature
and store together would pass. The bundle only *commits* to which store was
admitted, and a bundle that carries a store of its own is refused outright
rather than silently preferred.

The `attacker/` fixture exists to keep this honest. It is the same payload
re-signed with a different key, plus the store that key needs — internally
consistent in every respect. If any stage ever reads its root of trust from the
material it is validating, that fixture passes and the check is worthless.

## Later stages re-run admission; they do not re-check a subset

`admission-lib.sh` is the single implementation of admission semantics: input
schemas, candidate signature, closed candidate directory, identity and digest
equality across event/candidate/receipt/attestation, exact Release identity and
`published_at`, surface and channel selection, producer allowlist, and blob
anchoring. Admission, render and apply all run it. A rule enforced in one stage
only is not a rule.

Redundant identity fields are **re-derived** from the candidate and receipt
rather than read, so editing `identity.published_at` alone is caught.
`admission_id` is recomputed from the bundle's decision fields and compared
against a value the caller holds independently — which binds the stages of one
continuous execution. It is **continuity, not authentication**: a bundle moved
through untrusted jobs or storage would need a receiver-authenticated envelope,
which is deliberately not built here.

The closed input set is snapshotted **before** anything is validated, rejecting
symlinks, special files and unexpected entries during the copy. Everything
afterwards reads only the snapshot; verifying a source path and reading it again
leaves exactly the substitution window this is meant to close.

Renderer policy binding is on the **whole normalized relative path**, not a
basename, so a declaration of `receiver-downloads-index-policy.json` is not
satisfied by `alt/receiver-downloads-index-policy.json`.

## Authority is partitioned and never merged

| Value | Authority |
|---|---|
| version, tag, filenames, sizes, digests | the **verified candidate** |
| `published_at`, Release identity | the **Release receipt** |
| URLs, paths, channels, immutable prefix | the **surface declaration** |
| labels, primary, os/arch, kind, site MIME, selection, asset order | the **renderer config** |

`published_at` is the Release publication time, never the candidate's
`created_at` — 23 minutes apart for DocSort v0.4.3. The exception is the updater
feed, whose `pub_date` is the producer's record of the build; because that file
is byte-copied, whatever the producer wrote is preserved.

The renderers never read `receiver-publication.json`: it governs how the
receiver *serves* objects and disagrees with site-facing MIME for `.dmg`.

## Rendering is all or nothing

Every output is rendered, validated and hashed inside a private staging tree,
and `--outdir` is populated only after everything succeeds. An earlier version
wrote the channel pointer before validating the index and updater, so a bad
updater or a late equal-version conflict left a half-promoted directory for the
next stage to trip over.

- **Channel pointer** — `blessed/public-download-channel/v1`: version, tag, and
  the URL of the immutable signed manifest, and nothing else. Duplicating
  artifacts into a mutable file would create a second editable copy of facts the
  signature already covers.
- **Downloads index** — a bounded adapter for `docsort.io/downloads-index/v1`.
  The index is a running history: the existing file is validated against a
  strict adapter-local schema, every historical row is preserved, and exactly
  one row is prepended. A row that already exists for this tag is retained
  untouched when it is exactly equivalent and is a **conflict** otherwise —
  never silently replaced. URLs use the surface's declared
  `immutable_release_prefix`, not a hard-coded one.
- **Updater pointer** — validated and **byte-copied** from the candidate. Every
  platform URL must be a direct child of this release's immutable prefix, name a
  real candidate artifact, and advertise that artifact's actual detached
  signature.

## Promotion is forward-only

A backward promotion is refused: republishing an older version over a newer one
is a downgrade delivered by the update channel itself. Versions compare as
decimal strings component by component — shell arithmetic overflows, `jq`
numbers are doubles, and lexically `"9" > "10"`. Unparseable or non-canonical
live state is refused rather than treated as an empty channel.

## Committed bytes are verified, not assumed

Every git write runs with `core.hooksPath=/dev/null`. A receiver `pre-commit`
hook or a clean filter can otherwise replace an allowed output between `add`
and `commit`, and a gate that compares path *names* reports success while the
branch carries content nobody verified. After `add` and again after `commit`,
every blob is compared byte-for-byte with the independent re-render and
required to be mode `100644`; the staged set, the `base..HEAD` diff, and the
final worktree state must all match the allowlist exactly. Adoption applies the
same mode rule — blob text equal to a symlink target is not an output file.

## Equal bytes are not a replay

The same output can come from a rebuilt candidate, a recreated Release, or a
policy change that happens not to affect it. Publishing that silently under one
version is equivocation, so a no-op requires a **trusted prior promotion
record**: a MERGED PR from the strict snapshot whose head, base and merge
commit provably describe **one merge**, whose merged tree carries these exact
outputs at mode `100644`, and whose commit records the same promotion
authority. Apply writes that authority as a commit trailer, so the record lives
in the receiver's own history rather than in a new checked-in file. With no such
record the run fails closed for an owner decision.

The topology is checked, not assumed. A squash merge must have exactly the PR
base as its single parent and a tree equal to the promoted head's; a no-ff merge
must have the base and the promoted head as its two parents in that order. Both
must change exactly the allowlist from base to merge, and the merge must already
be contained in the admitted base's history — it may *be* that base, which is
exactly the state immediately after merging — while never being the **recorded
PR base** it is supposed to have advanced past. Checking each commit
in isolation would let a forged snapshot pair an arbitrary head carrying
valid-looking trailers with any base producing an allowlisted diff.

**When the promoted head is gone.** Deleting the branch on merge is ordinary
hygiene, and it makes a *squash*-merged head unreachable permanently — no
re-fetch brings it back. Requiring it would turn every squash-merged promotion's
replay into a `conflict` rather than the no-op it is. So when the head is not in
the object store, the **merge commit** must carry the whole proof by itself:

- exactly one parent, and that parent is the recorded PR base;
- `diff(base, merge)` is exactly the declared outputs;
- those outputs are byte-identical to the independent re-render and mode
  `100644`;
- the merge is already contained in the admitted base's history (it may be that
  base itself, the ordinary immediate-post-merge replay) and is not the recorded
  PR base;
- its own commit message carries the same `Promotion-Authority` and a canonical
  `Promotion-Admission` — GitHub's squash commit carries the promoted head's
  message, so the provenance survives the deletion.

The tree-equality check is the only thing the missing head costs, and the blob
and diff checks above cover the same ground directly. A **no-ff** record still
requires the head, because its second parent *is* the head — branch deletion
cannot unreach it. A squash whose body dropped the trailers proves nothing about
authority and still fails closed.

**Promotion authority** is the complete admitted decision with exactly two
exclusions: the wake event, because a replay legitimately arrives on a different
`repository_dispatch`, and the receiver base SHA, because the trusted base
advances once a promotion merges. Everything else is included — selected,
identity, receiver repo, candidate and signature, receipt, attestation, trust
store, signature-verification record, and the surface and policy commitments
*including their committed paths*. Hashing only the digests meant two
byte-identical declarations at different tracked paths shared one authority, so
adoption would accept the wrong configuration identity.

`Promotion-Admission` is validated as run-specific provenance — present and
canonical 64-hex — and is deliberately **not** compared for equality, because a
legitimate replay has a new admission id.

## Apply proves, then mutates

Apply re-runs admission, **independently re-renders** every output, and compares
the supplied manifest and every byte. A hand-edited rendered file is
uncommittable, and a file the manifest does not declare cannot ride along.

The receiver must be the declared repository — an **absent origin is a failure
to establish identity, not permission to skip the check** — at exactly the
trusted base, with the trusted base ref resolving to it, and a completely clean
index and worktree including untracked files. Destinations and ancestors are
preflighted for containment, traversal, symlinks, gitlinks and submodules
(including those whose `.git` is a file), special files, and case collisions;
the surface declaration and renderer policy are protected case-insensitively,
because on a case-insensitive filesystem a differently-cased path is the same
file.

Once the branch exists, every write, add and commit failure restores the
original base, branch state and HEAD. No partial mutation survives.

Publication must cover the **exact** required set: every signed `files[]`
payload, the published manifest, and **its detached signature** — a manifest
published without its signature cannot be verified by anyone downstream. URLs
are extracted per output schema and canonicalized against the public base,
because the index emits site-relative URLs a naive `https://` scan would never
see.

The PR snapshot is mandatory, must have asked about this exact head-ref prefix,
and must have covered OPEN, CLOSED and MERGED — a snapshot that never looked for
closed PRs cannot report their absence. Adoption requires the PR's base repo,
base ref and base SHA to be the trusted ones, a remote branch entry whose SHA
equals the PR head, both commits present locally, actual blob bytes equal to
what this promotion renders, and a diff touching nothing outside the allowlist.

### Every post-push state resumes

A failure between the push and PR creation used to strand the branch: the
create-only lease refuses to push again, and there is no update path. Because
the promotion commit is **deterministic** — identity and dates come from the
admitted decision, never the clock or local git config — a later run re-derives
the same sha and can tell its own stranded work from a stranger's.

The publication phase is therefore a small state machine:

| Remote state | Action |
|---|---|
| no branch, no PR | push, then create |
| branch at **this run's** commit, no PR | **resume**: skip the push, create |
| PR at this run's commit | already published; verify and stop |
| branch at any other sha | refuse; never touch a ref this run did not create |

A `create-pr` that reports failure is never believed on its own: the state is
re-read first, because the server may have created the PR while the client lost
the response. A definitive failure leaves the branch exactly where it is — that
*is* the resumable state — and deletes nothing, so a ref that moved concurrently
is never disturbed. Routine API failures need a re-run, not a human.

Every terminal path after the branch exists runs through **one finalizer** that
restores local state and asserts it: HEAD back at the trusted base, no local
promotion branch, and a clean index, worktree and untracked inventory. Two paths
once exited without it and left the receiver checked out on the promotion
branch, so the rerun they advertised as safe died at the local branch-exists
preflight. The finalizer touches nothing remote — the branch or PR is exactly
what the next run resumes.

### An assumption this tooling cannot discharge

The adapter re-reads the remote ref before each GitHub mutation, but that read
and the create/edit are separate API calls: GitHub exposes no compare-and-create
for pull requests. Another writer can move the ref in between, and the
post-publication read-back detects it only afterwards. Correct operation assumes
a **serialized writer** for promotion branches — a protected ref, or a single
publishing job. That is an explicit precondition for adopting this in Project C,
not something the generator can enforce.

The push itself is stronger: it uses a **create-only lease**
(`--force-with-lease` with an empty expectation), which succeeds only when it
*creates* the branch. That is the opposite of a force escape — it cannot
overwrite a ref and cannot even fast-forward one, so it can never rewrite a
concurrent promotion that appeared while this run was verifying.

Publication takes **two** snapshots through the adapter: one before pushing, to
detect a competing promotion that appeared while this run was verifying, and one
after, so the PR's head can be revalidated against the commit this run actually
made. Updating targets a PR proven to be this promotion — head repo, base repo,
base ref, base SHA, head SHA, blob bytes, modes and diff allowlist — never
whichever PR the API lists first. A failed PR query is **fatal**:
treating it as "no PRs found" would open a duplicate promotion every time the
API is unreachable, which is exactly when nobody is watching. The PR body is
deterministic and provenance-bound — producer SHA, candidate digest, surface,
channel, transport, admission id — so an equivalent re-run does not churn it.
The adapter creates or updates exactly one PR and never approves, merges, or
closes one. Per `rules/09-git-and-publication-boundaries.md`, interactive agent
sessions must not run it.

## The plan is explicit — never inferred

The producer supplies each artifact's `id` / `filename` / `platform` /
`install_kind` (+ optional `sbom`) in `blessed/release-candidate-plan/v1`. The tool
does **not** guess `platform`/`install_kind` from filenames — that breaks the moment
universal builds, Windows-ARM, or multiple installers per platform appear.

## Package repositories (`pkgrepo-*.sh`)

A `package-repository-surface` is a signed static APT/DNF repository built from
its reviewed inventory (`blessed/package-repository-inventory/v1`), with no
repository server. Five steps, each holding only what it needs:

```sh
# 1. GENERATE (no secret): the unsigned generation, byte-identical for the same inputs
pkgrepo-generate.sh --inventory inventory.json --pool pool/ --keys-dir keys/ \
  --timestamp "$(git log -1 --format=%ct -- inventory.json)" --tool-pins tool-pins --out gen/
# 2. SIGN (the repository key only): InRelease, Release.gpg, repomd.xml.asc
pkgrepo-sign.sh --generation gen/ --key-fingerprint "$REPO_FPR" --private-key-env REPO_KEY
# 3. VERIFY (public keys only): derive every object from the inventory and the
#    signed metadata; the unsigned manifest may only confirm
pkgrepo-verify.sh --generation gen/ --inventory inventory.json --emit-objects verified.json
# 4. PUBLISH (the store credential only): verify again, then create-only
#    immutables, a fenced claim, conditional entrypoint writes, confirm, read back
pkgrepo-publish.sh --generation gen/ --inventory inventory.json \
  --adapter adapters/s3-object-adapter.sh --expected-parent "$LIVE_GENERATION_ID"
# 5. CLIENT CHECK (inside a fresh target, as root): a real apt or dnf
pkgrepo-client-check.sh --format dnf --config-url https://…/rpm/<product>/<product>.repo \
  --key https://…/keys/repository.asc=$REPO_FPR --key https://…/keys/<producer>.asc=$PRODUCER_FPR \
  --install <name>=<version>-<release> --check '<name> --version' --upgrade-to <newer> --remove
```

What each step refuses is in the scripts' headers and in `CHANGELOG.md` 0.5.0;
the controls are `tests/test-pkgrepo.sh` (tooling) and
`tests/test-pkgrepo-clients.sh` (real Debian 13 apt, Fedora 44 dnf5).

**A generation's identity is its content.** `generation_id` is computed from the
inventory digest and every unsigned object (paths, classes, digests) by
`lib/pkgrepo-lib.sh`; the generator and the verifier compute it the same way, so
a manifest cannot name another generation.

**Activation is claimed, fenced and confirmed.** The live pointer
(`_state/generation.json`) holds `{generation_id, inventory_sha256,
parent_generation_id, state, claim_id}`. A publisher claims by compare-and-swap
before writing anything served; a re-run of an interrupted activation takes the
claim over with a new `claim_id`; each entrypoint write is conditional on the
version observed right after the claim, so a superseded publisher stops instead
of overwriting its successor. While a claim stands, only that generation's
publisher (a re-run) can finish it.

## Determinism contract

`release-candidate.json` is the exact bytes that get signed, so assembly is
byte-deterministic:

- UTF-8, **LF** line endings, exactly **one trailing newline**.
- **Stable object-key ordering** (`jq -S`).
- **Arrays sorted by stable identity** — `artifacts` by `id`, `files` by `name`.
- `created_at` is **supplied by the caller** (the plan); the tool never reads the
  clock.
- No filesystem-order or locale dependence.

⇒ the same plan + same payload produce a **byte-identical** manifest on every rerun,
on any host. `self-test.sh` proves rebuild and locale-independence.

`API_VERSION` (stable CLI contract) is `1`; artifact `VERSION` is released
independently and pins `signing` API 1 (`scripts/catalog.yml`). See
[`INSTALL.md`](INSTALL.md).
