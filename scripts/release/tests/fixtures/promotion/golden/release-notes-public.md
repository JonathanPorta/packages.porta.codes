# DocSort release notes

## v0.4.3

DocSort now checks that an update really is the version it claims to be, and
refuses to move backwards.

### Highlights

- **Updates are bound to their version.** Before downloading anything, DocSort
  fetches the signed release record for the version being offered, checks that
  signature against a key built into the app, and confirms the update feed it was
  served is exactly the one that record covers. An update whose advertised version
  does not match its signed release is refused.
- **No downgrades.** An update is only installed when it is genuinely newer than
  the version you are running. An offer to "update" to something older or
  identical is rejected.

### Correction to the v0.4.2 release notes

v0.4.2 said a tampered or substituted download could not be installed. That was
stated too broadly, and this release is what makes it accurate.

v0.4.2 verified the signature of the file it downloaded, so it would not install a
file that was not signed by the DocSort release key. What it did not check was
whether the file it was offered was the file belonging to the version being
advertised. Anyone able to alter the update feed could have paired a high version
number with an older, genuinely signed DocSort build — the signature check would
have passed and the older build would have installed. That is a downgrade or
replay, not arbitrary code: an attacker still could not have made DocSort install
something the release key had never signed.

Nothing suggests this happened. The v0.4.2 release notes are published as a
signed, content-addressed file and cannot be edited after the fact, so this is
where the correction lives.

### Upgrade notes

- If you are on v0.4.2, DocSort can install this release itself.
- Earlier versions have no working update endpoint and need a one-time manual
  install.

### Supported platforms

- macOS (Apple Silicon)
- Windows (x86-64)
- Linux (x86-64: AppImage, .deb)

Downloads are integrity-checked: every installer's SHA-256 is listed in `SHA256SUMS`,
and the release manifest is signed.
