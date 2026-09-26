# release changelog

## 0.5.0

### Added — package-repository-surface tooling (`releases.package-repositories@1`)

A static, signed APT/DNF repository built from its reviewed inventory, with no
repository server. Five steps, each holding only what it needs:

- **`pkgrepo-generate.sh`** (no secret): builds one UNSIGNED generation from the
  inventory and the package bytes it names — every package checked against its
  inventory digest and size, and its control file / RPM header against its
  inventory identity; every published key file must hold EXACTLY ONE primary
  key, the declared one (subkeys allowed) — a bundle that begins with the
  declared key and adds another is refused.
  APT: Packages/Packages.gz per architecture, a Release with
  `Acquire-By-Hash: yes`, by-hash copies of every index, and a deb822 `.sources`
  with a scoped `Signed-By`. DNF: `createrepo_c --no-database
  --unique-md-filenames` with revision and timestamps pinned, and one `.repo`
  per product (`$basearch`, `gpgcheck=1`, `repo_gpgcheck=1`,
  `skip_if_unavailable=False`, the repository key plus ONLY that product's
  producer keys). Tool versions must match a pins file exactly. Output is
  byte-identical for the same inputs, so an interrupted publication can
  regenerate. A generation manifest classifies every object immutable
  (packages, by-hash indexes, checksum-named repodata, keys) or mutable
  (entrypoints and configuration).
- **`pkgrepo-sign.sh`** (repository key only): signs only what the manifest
  names, after proving those files are unchanged — `InRelease`, `Release.gpg`,
  `repomd.xml.asc`. The key material must be exactly one primary secret key,
  the declared one. Key handling as `scripts/signing/sign.sh`.
- **`pkgrepo-verify.sh`** (public keys only) does NOT trust the unsigned
  generation manifest. It derives the complete object set — paths, classes and
  contents — from the inventory and the SIGNED metadata alone: packages
  against inventory digests and sizes; every index and its by-hash copy (by
  content) against signed `Release`; every repodata file against signed
  `repomd.xml`; APT Packages and DNF primary listing EXACTLY the inventory's
  packages; each RPM against ONLY its producer's declared key; each key file
  exactly its declared key; client configuration byte-identical to a
  re-render from the inventory (`lib/pkgrepo-lib.sh`, shared with the
  generator). The tree must be exactly that set — no extra, missing, symlinked
  or special file — and only then must the manifest agree in every path,
  class, digest and size. `--emit-objects` writes the verified object list. The
  `generation_id` is recomputed from content (inventory digest + unsigned
  objects, `pkgrepo_generation_id`), and a manifest naming another
  generation's id is refused.
- **`pkgrepo-publish.sh`** + **`adapters/s3-object-adapter.sh`**: publishes
  from the VERIFIER's object list, never the manifest, and never overwrites
  anything a client is served. Every object is created once (`If-None-Match:
  *`): shared immutables (packages, by-hash indexes, checksum-named repodata)
  at their advertised paths, and the generation's ENTRYPOINTS under
  `_generations/<generation_id>/`. It stats every object before writing
  anything (an existing path with different bytes is refused) and skips
  identical ones, so an interrupted publication resumes. The one replaced
  object is the activation pointer `_state/generation.json`
  (`blessed/package-repository-pointer/v2`: generation, inventory, generation
  record digest, a fresh never-reused `activation_revision`, and the
  predecessor it replaced). The plan is bound to `--expected-activation`; the
  pointer is read once and replaced by ONE conditional write on that read's
  version. A lost comparison voids the attempt — it is never re-read and
  retried. Rollback is a new activation of an older generation, so pointer
  bytes never repeat and an earlier plan can never match again (no ABA).
  Re-publishing the active generation, or any generation of an inventory
  already live (a replay), writes nothing. Nothing is deleted. The new
  revision is printed on stdout.
- **`pkgrepo-router.js`**: the read-only Cloudflare Worker in front of the
  store. Requests for stable entrypoint URLs read the pointer uncached and are
  served from the active generation's prefix with `Cache-Control: no-cache`;
  every other path passes through, so every advertised by-hash, package and
  repodata URL of every generation stays addressable. Only successful (2xx)
  responses for immutable URLs get an edge TTL (`cacheTtlByStatus`); any other
  status is never cached, so an origin error or a not-yet-present key recovers
  on the next request. No KV, Durable Object,
  database or lease; GET/HEAD only. `lib/pkgrepo-lib.sh`
  `pkgrepo_is_entrypoint` is the same rule, and the verifier refuses a
  generation whose classes disagree with it.
- **`pkgrepo-client-check.sh`**: a real apt or dnf, inside a fresh target,
  configured from the PUBLISHED configuration and keys — each key file checked
  to be exactly the expected key before it is trusted — installs, runs, upgrades and
  removes, or proves the client refuses.

Found with real clients: dnf5 never uses a `repomd.xml` whose signature fails,
but by default it skips that repository and exits 0. The generated `.repo`
sets `skip_if_unavailable=False` so a refusal is loud, and the verifier and
client check require it.

## 0.4.0

### Added

- `validate-surfaces.sh` and the packaged `release-surfaces.schema.json` accept
  a new surface kind, **`package-repository-surface`**
  ([`releases.package-repositories@1`](../../standards/releases/package-repositories.md)):
  a signed static APT/DNF repository shared by several producers. It carries
  `public_base_url` and a closed `package_formats` set (`apt`, `dnf`), and is
  forbidden the browser-download fields (`immutable_release_prefix`,
  `promotion_outputs`) — APT/DNF is not a download renderer. Cross-repo
  producers are legal only as `surface-pull` with a `repository_dispatch` or
  `workflow_dispatch` signal, the same authority model as the download surface.
- A package repository must own its base URL alone: a declaration in which it
  shares, contains, or sits inside another surface's `public_base_url` is
  rejected, since APT/DNF clients resolve every path beneath it.
- `package_formats` is rejected on every other kind.

- **`validate-package-inventory.sh`** and the packaged
  `package-repository-inventory.schema.json`
  (`blessed/package-repository-inventory/v1`): the authoritative state of a
  package repository surface. Repositories carry product, producer, channel,
  approved distro `targets` and architecture(s); packages name one repository.
  Beyond the schema it refuses duplicate JSON keys, duplicate or nested
  repositories, ambiguous product/format/channel/architecture mappings, empty
  repositories and inventories, packages from a producer that does not own the
  repository, files outside their repository or of the wrong format or
  architecture, RPMs without a declared signer of their producer, DEBs claiming
  one, duplicate package identities, one package name from two producers, and
  the repository key reused as a producer key.

Additive: every declaration valid under 0.3.x remains valid.

## 0.3.5

### Fixed

- The merged-promotion replay required the promoted head commit to still be
  readable. Deleting the branch on merge is ordinary hygiene, and it makes a
  **squash-merged** head unreachable permanently — so every squash-merged
  promotion replayed as `conflict` ("the trusted base already serves these exact
  bytes … but no MERGED promotion") instead of the no-op it is. Observed on the
  first real promotion, `docsort.io#74`.

  When the head is gone the **merge commit** must now carry the whole proof on
  its own: exactly one parent, which is the recorded PR base; a diff against
  that base equal to the declared outputs; those outputs byte-identical to the
  re-rendered ones and regular files; the merge already contained in the
  admitted base's history; and the same `Promotion-Authority` with a canonical
  `Promotion-Admission` in its own trailers. A **no-ff** record still requires
  the head, because its second parent *is* the head. A squash whose body dropped
  the trailers still fails closed.

## 0.3.4

### Fixed

- `apply-promotion-pr.sh` can now **recover an existing promotion PR** instead of
  leaving it permanently stuck. When `main` advanced under an open promotion, a
  re-drive refused the obsolete base *and* closing the PR refused as "a closed,
  unmerged promotion already exists for this version" — both doors shut, with no
  supported way out. The same dead end appeared when a branch update left a head
  whose `Promotion-Authority`/`Promotion-Admission` trailers survived only on a
  parent commit, because adoption reads them from the HEAD.

  Recovery runs only after the existing identity checks establish the PR *is*
  this promotion: same repository, trusted base ref, this promotion's branch,
  branch and PR heads agreeing, and both commits readable. It then re-derives the
  outputs from the verified bundle and mints fresh trailers from the admission id
  and authority. Nothing is copied from the old head to make validation pass.

  Eligibility is decided from **commit ancestry**, never from the snapshot's
  `base_sha`: GitHub reports a PR's base as the target branch's current tip,
  not the commit the branch forked from, so `main` can advance under a
  promotion while the snapshot still names the admitted base. The fork point
  (the merge base of the trusted base and the head) separates what the branch
  inherited from `main` from what was edited on the branch. A fork point behind
  the trusted base is the recoverable "main advanced" state; the branch-only
  diff from the fork point must be **exactly** the declared outputs, whatever
  the base.

  Still refused: a different authority, **different bytes** at a declared
  output, a missing or non-regular output, any branch-only addition, edit,
  deletion or mode change outside the declared outputs, a head with no shared
  history or an ambiguous fork point, and every prior identity refusal.
  Recovery may bring a head up to date; it may never discard content that is
  not this promotion. Adoption is still attempted first, so an unchanged
  re-run remains a no-op.

### Added

- The publication adapter's `push` takes an optional expected-remote-OID, making
  the lease a **compare-and-swap** (`refs/heads/<branch>:<oid>`) on the recovery
  path. A branch moved by anyone else fails the lease rather than being
  overwritten; without the argument the push stays create-only. This is not a
  general force escape — it can replace only the one head the caller already
  verified belongs to this promotion.

- Three controls: a head with the right bytes but no provenance is recovered
  rather than adopted; an obsolete base is recovered rather than refused; and
  recovery pushes under a lease naming the exact observed head. The superseded
  obsolete-base refusal now asserts what must still fail — a base this run
  cannot read, since nothing can be decided from a self-reported value.

## 0.3.3

### Fixed

- The **surface manifest** is no longer conflated with the producer's signed
  envelope. `apply-promotion-pr.sh` required the envelope to be published at
  `manifest.json` carrying the CANDIDATE's digest, plus a `manifest.json.sig`
  no contract defines, and refused the real DocSort v0.4.4 publication with
  three symptoms of that one error. Per the owner decision of 2026-09-19,
  `manifest_url` names the surface-owner-authored `manifest.json`
  (`blessed/public-download-manifest/v1`), while the envelope stays published
  as `release-candidate.json` with its original signature. Both
  `public-download-channel.schema.json` copies drop the incorrect claim that
  `manifest.json` is a rename of the envelope — a claim no published surface
  has ever matched.

- The surface manifest is now **validated and bound**, not accepted for being
  present. `--surface-manifest` is REQUIRED, and the supplied bytes must match
  the digest and size the publication attestation recorded, conform to the new
  schema, and project the ADMITTED, signature-verified candidate: release
  identity, the candidate digest, `source_sha`, `signing_key_id`, the envelope
  URL, and for every asset the id, install_kind, platform, sha256, size and
  canonical URL — in both directions, so a projection that drops an artifact is
  refused too. Release metadata is bound as well: `published_at` to the Release
  receipt, `name` to the candidate, and the notes URL must name the candidate's
  public notes AND be an attested published object.

- The receipt backing that binding is read from the AUTHENTICATED snapshot,
  not from the caller-owned bundle directory. It was the only post-verification
  read of `$bundle` in the script; there are now none.

### Added

- `public-download-manifest.schema.json` (both copies) — written from the
  format already published at docsort.io and checked key-by-key against the
  live v0.4.4 document.

- `tests/test-promotion.sh` grows to 293 controls, including a valid
  projection accepted, a wrong-schema manifest refused, a projection of another
  candidate refused though internally consistent, altered hash / dropped
  artifact / non-canonical URL refused, altered `release.name` and
  `published_at` refused, an in-prefix but unpublished notes URL refused, and a
  source-bundle mutation after snapshotting refused rather than adopted.

## 0.3.2

### Fixed

- `render-updater-pointer.sh` no longer derives the expected artifact platform
  from a hand-written table. The table read
  `{"darwin-aarch64":"darwin/arm64", ..., "linux-x86_64":"linux/amd64",
  "windows-x86_64":"windows/x86_64"}` — expecting Go's `amd64` for linux but
  uname's `x86_64` for windows, which is no vocabulary at all. It had been
  transcribed from a v0.4.3 fixture and matched no producer declaration: the
  real DocSort v0.4.4 candidate declares `darwin/aarch64` and `linux/x86_64`,
  as `release-artifacts.json` has since #224, and the renderer refused it after
  its signature had already verified.

  `platform` is schema-free-form (`^(any|[a-z0-9]+/[a-z0-9_]+)$`), so both
  spellings conform and neither is canonical. The expected platform is now
  derived from the feed's platform KEY (`linux-x86_64` → `linux/x86_64`) and
  both sides are normalized onto one arch vocabulary before comparison. The
  bounded set of recognized keys is unchanged. The property this check defends
  — no coherent swap of a URL and its genuine signature onto another platform's
  artifact — is "same OS, same ARCHITECTURE", not "same spelling", and a
  cross-architecture or cross-OS swap is still refused.

- The advertised signature's encoding now follows the artifact's DECLARED
  signature profile instead of being assumed for the whole envelope:

    - `ed25519-detached-v1` — the sidecar holds raw bytes, so the feed
      advertises base64 of them (unchanged behaviour).
    - `tauri-minisign-v1` — the sidecar is already a base64 document, so the
      feed carries the file's bytes verbatim.

  The previous code base64'd the sidecar unconditionally, which double-encodes a
  Tauri sidecar and therefore could never match. It refused the real v0.4.4
  candidate, whose three updater payloads declare
  `signature_profile: tauri-minisign-v1` — the heterogeneity
  `releases.candidate@1` explicitly allows. Each profile has exactly one
  accepted encoding of exactly one file; there is no "try both" fallback, so a
  mis-declared artifact cannot match either way.

  Both defects were found by rendering the real, signed v0.4.4 candidate; each
  was a refusal of a conforming candidate, not a missing guard.

- The `tauri-minisign-v1` signature comparison is now **byte-for-byte**, not a
  newline-stripped string compare. The first fix computed the sidecar side with
  `tr -d '\r\n'` and described the result as "verbatim", which deletes
  content-bearing bytes and contradicts `signing.tauri-minisign@1` ("Preserve it
  byte-for-byte; do not extract only one base64 line, normalize comments, or
  rewrite newlines"). The advertised value is also no longer carried through
  `jq @tsv`, which escapes an embedded newline as a literal `\n`; it is read per
  platform with `jq -rj` into a file and compared with `cmp`, so neither the
  transport nor command substitution can rewrite it.

  Nothing is normalized, not even a trailing newline. `releases.runtime-update@1`
  requires the advertised signature to equal the EXACT sidecar whose size and
  digest the candidate authenticates, so a sidecar with a terminator advertised
  without one is not that sidecar, and accepting it would weaken the binding
  this guard exists to enforce. No conforming artifact needs the tolerance — the
  real v0.4.4 sidecars are 404 and 420 bytes with zero newlines. Supporting a
  newline-terminated producer would be a change to the feed/profile contract and
  its schema, not a receiver-only equivalence.

  Worth recording for future readers: a Tauri sidecar is base64 OF the two-line
  Minisign document, so the real v0.4.4 sidecars are single-line — 404 and 420
  bytes with zero newlines — and the encoding already preserves the document's
  line structure. A multi-line value cannot reach this comparison at all,
  because the schema rejects it during feed validation.

### Added

- `tests/test-promotion.sh` gains fifteen controls covering all three fixes. For the
  platform binding: the fixture's `linux/amd64` and the other spelling
  `linux/x86_64` are both accepted under `linux-x86_64`, `darwin/aarch64` is
  accepted under `darwin-aarch64`, while a different architecture under the same
  OS, a different OS with a matching architecture, and an arch outside the alias
  set are each still refused. For the signature encoding: a `tauri-minisign-v1`
  artifact is accepted when the feed carries its sidecar verbatim and refused
  when it carries base64-of-file, and an `ed25519-detached-v1` artifact is
  refused when advertised verbatim — so neither profile silently accepts the
  other's encoding. For byte-exactness: an exact single-line sidecar is
  accepted, a single trailing newline still matches, and an interior newline,
  two trailing newlines, a truncation and a changed byte are each refused.


## 0.3.1

### Fixed

- `admitted-bundle.schema.json` no longer requires a `Z` suffix on
  `identity.candidate_created_at`. No upstream schema imposed that:
  `release-candidate.schema.json` and `candidate-plan.schema.json` both declare
  `created_at` as `format: date-time` with no pattern, so a producer emitting a
  legal RFC3339 numeric offset — which is what `git show %cI` produces — built a
  VALID candidate that could never be admitted, because `bundle-verify.sh` binds
  the bundle field to the candidate's value verbatim. The binding is the
  invariant; the extra pattern only made two shipped contracts disagree with each
  other. Found by the first real promotion of a production candidate
  (DocSort v0.4.4, `2026-09-15T03:10:20-06:00`).

### Added

- `tests/candidate-created-at.test.sh` — pins both halves of the above, so the
  relaxation cannot drift into a weakening: `Z`, numeric offsets and fractional
  seconds are accepted; malformed values including impossible calendar dates and
  hours are still rejected by `format: date-time`; and the verbatim binding still
  catches a bundle timestamp that differs from its candidate even when both are
  well-formed and denote the same instant. The binding case drives the shipped
  `bundle_verify` against a real admitted bundle rather than restating its
  comparison, so it would fail if bundle-verify.sh stopped checking.

- `updater-pointer.schema.json` (both copies) drops the same `Z`-only pattern on
  `pub_date`, for the same reason: it is CANDIDATE-DERIVED, and the candidate
  contract permits a numeric offset. A conforming, correctly signed candidate
  carrying one passed schema, closure, hashes, manifest signature and every
  artifact signature, then died in the renderer with no output and nothing to fix
  in the producer. `format: date-time` still rejects malformed values.
  `public-download-channel.schema.json`'s `published_at` is deliberately NOT
  changed — that is the Release publication time carried verbatim from the
  receipt, not a candidate-derived field.

### Changed

- The normative `standards/releases/references/admitted-bundle.schema.json` is
  updated alongside the vendored copy. The two are byte-identical on master and
  must stay so; changing only one would leave the normative contract and the
  shipped category disagreeing about what a conforming candidate may carry.

## [0.3.0] - 2026-08-28

Adds the deterministic promotion generator: the second half of the release
path, turning a signed candidate into a reviewed pointer change on a public
surface.

### Added

- `admit-candidate-ready.sh` — the trust boundary. Requires a verified candidate
  signature against an out-of-band trust store; prints an `admission_id`.
- `lib/admission-lib.sh` — the single implementation of admission semantics,
  run by admission, render and apply alike.
- `lib/bundle-verify.sh` — re-runs the whole of admission at every actionable
  stage over a snapshot taken before anything is read.
- `render-promotion.sh` — all-or-nothing rendering into a private staging tree,
  plus a render manifest binding outputs to the admission.
- `render-downloads-index.sh` — bounded adapter for one foreign format, which
  preserves the site's release history and honours the declared immutable
  prefix.
- `render-updater-pointer.sh` — validates and byte-copies the producer's signed
  updater feed.
- `apply-promotion-pr.sh` — re-admits, re-renders, compares every byte, enforces
  the git and filesystem boundary, proves publication completeness, and upserts
  exactly one PR through an injected adapter.
- `adapters/gh-pr-adapter.sh` — the credentialed publication adapter. A failed
  PR query is fatal; it never approves, merges, or closes.
- Ten schemas: `release-candidate-ready/v1`, `release-receipt/v1`,
  `publication-attestation/v1`, `public-download-channel/v1`,
  `updater-pointer/v1`, `admitted-bundle/v1`, `render-manifest/v1`,
  `pr-state-snapshot/v1`, `downloads-index-renderer-config/v1`, and the
  adapter-local `docsort-downloads-index/v1`. With the three that already
  existed, the packaged category now carries thirteen.
- `tests/test-promotion.sh` — controls over three fixtures: a genuinely signed
  candidate, an attacker-signed chain that is internally consistent and wrong,
  and a golden fixture mirroring the live docsort.io values.

### Changed

- `blessed/release-surfaces/v1` gains `renderer_config` on promotion outputs. A
  `downloads-index` output without one is rejected: presentation policy has no
  authority in the signed candidate.

### Security notes

Every git write disables hooks, and staged and committed blobs are verified
byte-for-byte at mode 100644. A gate that compares path names lets a
`pre-commit` hook replace verified content while reporting success.

Equal output bytes do not establish equal authority. A no-op requires a locally
verifiable prior promotion carrying the same promotion authority, recorded as a
commit trailer; absent that, the run fails closed rather than assuming a replay.


The trust store is supplied to every stage **independently of the bundle**. A
store carried alongside the artifact it validates is not a root of trust, and an
earlier draft of this work shipped exactly that mistake.

`admission_id` binds the stages of one continuous execution. It is continuity,
not authentication: moving a bundle through untrusted jobs or storage would
require a receiver-authenticated envelope, which is deliberately not built here.

The published candidate is the manifest, **its detached signature**, and every
`files[]` payload. Publishing a manifest without its signature leaves nothing
downstream able to verify it.

### Recovery

The promotion commit is deterministic, so every post-push state is resumable: a
later run re-derives the same sha, recognises its own stranded branch, and skips
the push. A create-pr failure is re-read before being believed, since the server
may have succeeded while the client lost the response. Nothing is ever deleted,
so a concurrently moved ref is never disturbed.

### Adoption precondition

GitHub exposes no atomic compare-and-create for pull requests. The adapter reads
the remote ref before each mutation and reads back afterwards, which narrows and
detects the window but cannot close it, so safe operation assumes a serialized
writer for promotion branches — a protected ref or a single publishing job. The
push is stronger: a create-only lease that cannot overwrite or fast-forward an
existing branch.

### Notes

`published_at` comes only from the Release receipt, never the candidate's
`created_at` — 23 minutes apart for DocSort v0.4.3. The updater feed's
`pub_date` legitimately is the build time, and byte-copying preserves it.

Building the fixture surfaced a gap in the candidate contract: a plan cannot
declare a payload file that is not an artifact, so an updater feed is modeled as
an artifact with `install_kind: other`. Not a blocker.

## [0.2.3] - 2026-08-20

- **YAML preflight probes now fail closed.** None of the probe pipelines captured
  an exit status, so a partial tool failure passed open: a yq that errored only
  on the anchor query left a document containing a forbidden anchor reported as
  `OK`, while the later successful conversion silently expanded it. Every probe
  now captures and checks its status. `JQ_BIN` mirrors `YQ_BIN` so the jq-side
  paths are testable rather than asserted.
- **Probes run in the current shell.** They were wrapped in command
  substitution, where `die` exits only the subshell — which downgraded a tooling
  failure to a plain INVALID verdict.
- **Malformed input is INVALID, not a tooling failure.** A probe cannot tell a
  malformed document from a broken tool, so parseability is now established once
  up front. A typo reports "not parseable as YAML" (rc=1) instead of claiming the
  toolchain is broken (rc=2).

## [0.2.2] - 2026-08-20

Controls that could fail OPEN are closed. Several checks in 0.2.1 could report a
clean result while verifying nothing.

- **The canonical schema is no longer overridable.** `--schema` let a caller
  substitute a permissive schema; a document declaring
  `schema: totally-not-release-surfaces` validated as OK. The flag is removed and
  rejected as an unexpected argument; the packaged schema is always used.
- **Every validator stage fails closed.** The packaged library is required to
  exist, source, and define its function; the schema validator's output and exit
  status are captured independently; a nonzero status with empty output is a
  TOOLING failure, never a verdict. The semantic jq status is captured the same
  way.
- **Explicit YAML tags are detected properly.** yq reports the same tag for
  implicit and explicit values, so tag identity cannot distinguish them —
  explicitness is `style == "tagged"` on scalars and `<unknown>` on collections.
  Scans now use `...` rather than `..`, so mapping KEYS are inspected too.
- **yq is pinned to exactly 4.53.2.** Advertising a 4.40.0-4.53.2 range claimed
  coverage CI has never executed. The byte cap is a HARD maximum that
  `SURFACES_MAX_BYTES` can lower but never raise.
- **Collision namespaces corrected.** Output identity is (surface, id), renderer
  identity is (surface, role, channel), repository destination is
  (lowercase owner_repo, repo_path), and public/immutable namespaces key on the
  resolved URL. Independent surfaces may now legitimately reuse ids, role/channel
  pairs, and relative paths, while equal resolved destinations collide.
- **Explicit ports forbidden** in `public_base_url`: `:443`, `:0443`, and an
  omitted port all denote the same authority, and partial normalization is a trap.
- **GitHub slug grammar corrected.** Owner and repository have separate
  definitions; the owner cap applies to the whole 39-character token rather than
  to hyphen-joined groups, which had let a 46-character owner through.

## [0.2.1] - 2026-08-20

Two authority-bearing invariants tightened after review of 0.2.0.

- **Canonical GitHub identity.** The repo pattern was a permissive
  approximation: it accepted `invalid_owner/repo` (owners cannot contain
  underscores) while rejecting the legitimate special repository `Owner/.github`.
  It now uses the actual grammar — owner alphanumeric with single interior
  hyphens, no leading/trailing or consecutive hyphens, max 39; repository
  `[A-Za-z0-9._-]` up to 100 but never `.` or `..`. These strings are authority
  and collision keys for the generator, so an impossible identity must not parse.
- **One canonical HTTPS spelling.** `https://example.com:443/downloads/` and an
  uppercase host were accepted as distinct spellings of the same authority. The
  redundant default port and non-lowercase hosts are now rejected; an explicit
  non-default port remains legal.
- **Unique immutable publication namespaces.** Two surfaces could claim the same
  immutable object namespace whenever their mutable output paths differed. The
  canonical key is now `public_base_url + immutable_release_prefix`, compared
  across the document for equality AND nesting — which also catches an equivalent
  namespace written with a different base/prefix split.

## [0.2.0] - 2026-08-20

**First executable canonical definition of `blessed/release-surfaces/v1`.** That
contract carried `proposal` status with no canonical schema and no consumer
validator, so its examples had drifted into mutual contradiction. Those examples
are reconciled IN PLACE rather than minting a v2 to preserve unenforced
contradictions.

- `validate-surfaces.sh` — new CLI. A bounded YAML preflight, exactly one pinned
  yq v4 conversion, the packaged JSON-Schema validator, then semantic checks.
- `references/release-surfaces.schema.json` — packaged copy, byte-identical to
  the normative `standards/releases/references/` original (self-test asserts it).
- **New dependency: `yq` (mikefarah v4).** Required only by `validate-surfaces.sh`;
  the candidate/plan CLIs still need only `jq`. CI pins an exact release and
  SHA256, and the CLI verifies flavor plus an explicitly tested version range —
  it refuses the python-flavor yq, anything older than the tested minimum, and
  anything newer than the tested maximum. Arbitrary future v4 releases are not
  assumed compatible.
- The preflight exists because YAML->JSON conversion ERASES constructs a
  post-conversion JSON check can never see. Duplicate keys are the sharpest case:
  yq emits duplicate JSON keys at exit 0 and jq then silently keeps the last.
  Also rejected: multiple documents, anchors, aliases/merge keys, explicit and
  custom tags, non-object roots, oversized input, and any nonzero conversion
  (whose stdout is discarded rather than parsed).
- Semantic checks cover what a JSON Schema cannot: document-wide uniqueness of
  surface ids and promotion-output identity, cross-repo authority detection using
  case-insensitive GitHub identity, the closed kind x publisher x transport
  compatibility matrix, and collisions between public paths and the immutable
  release prefix.

This CLI is STATIC. It never writes, never resolves a path on disk, and makes no
claim about symlink safety or atomicity — those belong to the promotion
generator, not here.

## [0.1.6] - 2026-08-20

- **Packaged validator picks up the RFC 3986 `dec-octet` fix.** The IPv6 `ls32`
  branch used a looser octet pattern, so an IP-literal with a leading-zero octet
  (`[::ffff:01.2.3.4]`) received a clean `format: uri` result. Resynced from the
  shared validator, which now matches the exact production; the self-test's
  byte-identity control keeps the two copies locked together.

## [0.1.5] - 2026-08-20

- **The packaged category is dependency-closed again.** 0.1.4 delegated schema
  validation to a sibling `scripts/lib-json-schema.sh`, which the released
  tarball (`tar -C scripts ... release`) does not contain — a consumer installing
  the pinned artifact had validation refuse every input (blessed-cicd#252 F3).
  The validator now ships at `lib/lib-json-schema.sh`, is covered by the
  manifest, and the self-test asserts it is byte-identical to the repo's shared
  copy so the two cannot drift. No new install dependency.

## [0.1.4] - 2026-08-20

- **Schema validation delegates to the repo's single shared implementation.**
  This category carried its own regex-only validator, so a format rule fixed in
  `scripts/lib-json-schema.sh` stayed broken here — `validate-plan.sh` accepted
  an impossible leap-second `created_at` that the shared validator rejected
  (blessed-cicd#252). `rel_schema_validate` now sources the shared library and
  fails closed if it is missing, rather than silently validating less. No change
  to the plan/candidate schemas themselves.

## [0.1.3] - 2026-08-17

- **Native dispatch proven end to end.** The self-test previously proved routing
  with a stub adapter over fake sidecar bytes. It now also builds a candidate
  whose artifact is the signing category's committed `tauri-minisign-v1`
  known-answer vector and validates it through the real `verify-native.sh` — no
  stubs in the path — plus a control proving a mutated native artifact is
  rejected. Requires `signing` >= 0.2.0 for the native profile; the fail-closed
  behavior when no adapter is present is unchanged.

## [0.1.2] - 2026-08-15

- **Native updater signature metadata:** the packaged candidate schema now
  accepts the optional `signature_profile` and `signature_key_id` fields used
  to bind a runtime-native updater signature, while the candidate envelope
  remains `ed25519-detached-v1`. Semantic validation requires the signature,
  profile, and key id as one complete tuple. The packaged schema remains
  byte-identical to the normative standard.
- **Artifact verification dispatches on the artifact's own profile/key id:**
  `validate-candidate.sh` previously verified every required artifact sidecar
  with the manifest's `ed25519-detached-v1` profile and `signing.key_id`, which
  checked the wrong cryptographic contract for a native sidecar while still
  reporting a valid candidate. It now resolves the effective profile/key per
  artifact, routes `ed25519-detached-v1` to the signing CLI and a native profile
  to that profile's adapter (`<signing-dir>/verify-native.sh`), and fails closed
  on a missing adapter, an unrecognized profile, or a key id that is not an
  active trust-store key bound to that profile.
- **Assembly preserves adapter metadata:** `rel_build_candidate` carries
  `signature_profile` / `signature_key_id` from the plan into the candidate
  (and refuses a half-declared override or one without a sidecar), so a plan
  that declares a native adapter can produce a conforming candidate. The plan
  schema accepts the same optional pair.

## [0.1.1] - 2026-07-19

- **Closed candidate dir:** `validate-candidate.sh` now enforces the candidate
  directory as a FLAT envelope of exactly `release-candidate.json` +
  `release-candidate.json.sig` + the manifest `files` payload — rejecting any
  unlisted regular file, **symlink** (including a listed artifact swapped for a
  symlink, which recompute alone would follow and match), directory/nested entry,
  FIFO/socket/device, or unsafe/newline filename. NUL-scanned. Found + hardened by
  the release-v0.1.0 smoke test and review.

## [0.1.0] - 2026-07-19

Initial release. Candidate assembly + validation, `API_VERSION` 1; requires
`signing` API 1.

- `build-candidate.sh` — deterministic `release-candidate.json` from an explicit
  `blessed/release-candidate-plan/v1` plan (no filename inference); emits
  `provenance.json` + `SHA256SUMS`; `created_at` from the plan (no clock).
- `build-provenance.sh` — `blessed/release-provenance/v1` from the plan.
- `validate-plan.sh` / `validate-candidate.sh` — schema + semantic closure + on-disk
  hash recompute; with a trust store, verifies the manifest signature (and required
  artifact sigs) through the `signing` CLI (never sources signing-lib / calls openssl).
- `lib/release-lib.sh` — assembly, subset JSON-Schema validator, closure checks,
  recompute, signing-API check.
- `references/` — candidate-plan schema + a packaged copy of the candidate schema
  (drift-tested against the normative source).
- `self-test.sh` — 12-check suite: plan validation, deterministic + locale-independent
  assembly, schema conformance, schema-drift, pre-sign validation, full build→sign→
  validate, and negatives (on-disk tamper, manifest tamper, unknown key_id, API mismatch).
