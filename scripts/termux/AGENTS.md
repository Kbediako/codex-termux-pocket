# Termux maintenance and release agent rules

These instructions apply to every file under `scripts/termux/`.

Before changing alpha maintenance, release evidence, the updater, or a promoted
manifest, read:

- `../../docs/termux-release-runbook.md`
- `../../docs/termux-maintainer.md`
- `../../.github/workflows/README.md`

Required invariants:

- record the annotated upstream tag, peeled upstream commit, fork merge commit,
  and exact clean source SHA separately;
- prove upstream ancestry instead of assuming a merge-parent position;
- classify every retained fork commit in `patch_audit.tsv`;
- never reuse validation from another source SHA;
- never write `release-manifest.env` before the public release has been
  anonymously downloaded and verified;
- the repository manifest must match the public `release-manifest.env`
  byte-for-byte and identify the same release tag, source, binary, digest, and
  sizes;
- failed or incomplete issue evidence must be replaced with final evidence before
  the tracker closes;
- do not weaken checksum, metadata, SBOM, attestation, rollback, or source
  validation to make a release pass.

When adapting an older maintenance script, do not perform an unchecked global
version/token replacement. Syntax-check generated shell, keep bootstrap and
transaction directories distinct, and inspect the generated execution region
before dispatch.
