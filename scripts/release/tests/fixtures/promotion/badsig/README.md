# `badsig/` — everything consistent except the signature

A schema-valid field of the signed candidate was changed and **the original
signature kept**. Every derived value is recomputed to match: event, receipt and
attestation digests, and — when a bundle is built from it — the commitments,
redundant identity fields, `admission_id`, and the caller-held expected id. The
external trust store is the legitimate one.

The only thing wrong is the signature, so this fixture isolates
`validate-candidate.sh`. Without it, an "attacker chain" control can pass while
signature verification is never reached at all: bundle-commitment and
trust-store checks fire first and hide it. Each of admit, render and apply must
reject here specifically at signature verification, with no output and no
repository mutation.
