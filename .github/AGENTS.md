# Termux CI and release agent rules

These instructions apply to every file under `.github/`.

Before an upstream alpha sync, CI repair, release publication, or takeover of an
unfinished maintenance issue, read these files completely:

1. `../docs/termux-release-runbook.md`
2. `workflows/README.md`
3. `../docs/termux-maintainer.md`

The runbook is the completion contract. In particular:

- inspect the complete failed job log before editing;
- peel annotated upstream tags and prove ancestry with
  `git merge-base --is-ancestor`;
- never require `HEAD^2` on a retry;
- use only exact-source successful gates with matching `head_sha`, workflow path,
  matrix jobs, and retained artifacts;
- do not let Actions edit workflow YAML;
- do not add a one-off workflow without explicit repository-owner approval;
- only `workflows/termux-release-request.yml` may publish a release;
- publish every final asset from a draft and make it Latest in the same
  draft-to-public transaction;
- anonymously verify public bytes, checksums, metadata, SBOM, attestations,
  `target_commitish`, the tag ref, and `/releases/latest` before promoting the
  updater manifest;
- explicitly run permanent post-promotion checks on final cleaned `main` when a
  workflow-token commit does not trigger them recursively;
- remove all temporary jobs, scripts, workflows, and branches before closing the
  maintenance tracker;
- never claim a cancellation, deletion, publication, or successful run until a
  live GitHub read confirms it.

When using a connected GitHub tool, discover its write actions before describing
the connection as read-only. File writes, Git-data commit/ref operations, issue
mutation, and Actions controls may be exposed as separate schemas.
