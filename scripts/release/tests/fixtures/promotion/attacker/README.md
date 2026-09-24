# `attacker/` — a complete, internally consistent, WRONG chain

The same payload bytes as `signed/`, re-signed with a **different** ed25519 key,
together with the trust store that key would need. Everything here validates
against itself: the manifest signature verifies, every artifact signature
verifies, every digest agrees.

It exists to prove one thing — that supplying candidate, signature and trust
store *together* does not get you admitted. If any stage ever reads its root of
trust from the material it is validating, this fixture passes and the check is
worthless. The private key was destroyed, like the real fixture's.
