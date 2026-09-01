# Termux Maintainer Guide

This workflow is intentionally separate from installation on a phone. Only a
maintainer refreshing the fork's patch stack should integrate OpenAI alpha tags.
Before any alpha sync, CI repair, publication, or takeover, read
[`termux-release-runbook.md`](termux-release-runbook.md) completely.

## Refresh the patch stack

Start from a clean `main` checkout and run:

```shell
scripts/termux/maintainer-update-alpha --tag rust-vX.Y.Z-alpha.N
```

The helper configures `origin` as the Termux fork and fetch-only `upstream` as
OpenAI. It fetches upstream tags and prepares the maintained patch stack; it does
not stash, push, force-push, publish, or silently resolve conflicts. Review every
conflict and classify every retained fork commit in
`scripts/termux/patch_audit.tsv`.

After integration, validate the complete locked graph. To refresh only the lock
state after reviewed conflict work:

```shell
scripts/termux/maintainer-update-alpha --lock-only
```

When dependency changes require it, also run `just bazel-lock-update` on a
supported host and commit `MODULE.bazel.lock` with `codex-rs/Cargo.lock`.

## Record separate identities

An annotated tag object is not the source commit. Peel it and keep four values
separate:

```shell
upstream_commit="$(git rev-parse 'refs/tags/rust-vX.Y.Z-alpha.N^{}')"
git merge-base --is-ancestor "$upstream_commit" "$source_sha"
```

```text
upstream_tag=<official annotated tag>
upstream_commit=<recursively peeled OpenAI commit>
merge_commit=<fork integration commit, when applicable>
source_sha=<clean exact fork source used by every runtime gate>
```

A retry may create an ordinary single-parent commit. Never require `HEAD^2`;
ancestry is the durable proof.

## Select a clean source before running gates

Remove every temporary maintenance workflow, job, script, helper, branch, and
issue trigger before selecting `source_sha`. The source should already contain
all intended runtime and permanent release-control changes. Do not move `main`
until its exact-source gate set has finished, because manual workflow runs report
the branch head as their `head_sha`.

## Run all exact-source gates

The same full SHA must have successful live runs of:

- `.github/workflows/blocking-ci.yml` (`Termux fork checks`)
- `.github/workflows/termux-control-plane.yml`
- `.github/workflows/termux-linux-sandbox.yml`, including x64 and ARM64
- `.github/workflows/termux-mobile-artifact.yml`
- `.github/workflows/termux-android-emulator.yml`, including fixture and real app

Dispatch the sandbox and artifact workflows with `source_ref=<source_sha>` while
`main` still equals that source. Dispatch Android manually on that same `main`.
Do not duplicate an exact run that is queued or running. Inspect the complete log
of any failed job, repair only evidenced defects, choose the repaired commit as a
new source, and restart the whole gate set.

The production artifact run must retain exactly one unexpired artifact named
`codex-termux-aarch64-unknown-linux-musl`.

## Prepare the publication request

After all five runs are green, update
`scripts/termux/release-publication.env` using format 2:

```text
format_version=2
source_sha=<40-character exact runtime source>
release_tag=termux-v<package-version>-<first 10 source characters>
expected_package_version=<X.Y.Z-alpha.N[.P...]>
expected_codex_version=codex-cli <first 7 source characters>
fork_ci_run_id=<successful exact Fork CI run>
control_run_id=<successful exact control-plane run>
sandbox_run_id=<successful exact x64+ARM64 sandbox run>
artifact_run_id=<successful exact ARM64 artifact run>
android_run_id=<successful exact Android/Termux run>
```

Each run ID must be distinct. Commit this request to protected `main`; that push
starts the only release writer, `.github/workflows/termux-release-request.yml`.

## Executable release contract

`.github/scripts/termux_release_control.py` owns the release state machine:

1. `validate-request` re-fetches all five runs, exact jobs, and the retained
   artifact, and proves `source_sha` is an ancestor of current `main`.
2. `prepare` verifies `SHA256SUMS`, strict metadata, archive safety, all internal
   runtime checksums, `codex-package.json`, and SPDX package/source identity,
   then creates `release-manifest.env` as the fifth asset.
3. `publish` creates a draft, uploads all five assets, verifies the complete
   draft, and makes it public and GitHub Latest in one update.
4. `audit` anonymously downloads all five files, compares the bytes with the
   attested candidate, checks GitHub API sizes/digests, metadata, archive,
   checksums, SBOM, tag ref, `/releases/latest`, and publisher attestations.
5. `promote` accepts only the same-job audit receipt and rechecks live release
   identity before updating `scripts/termux/release-manifest.env`.

The public release is never repaired incrementally. An abandoned exact draft may
be deleted on retry; a conflicting public tag or release is a hard failure.

## Production artifact contract

`termux-mobile-artifact.yml` builds one source and target, then retains:

```text
codex-termux-aarch64-unknown-linux-musl.tar.gz
codex-termux-sbom.spdx.json
metadata.env
SHA256SUMS
```

The publisher adds `release-manifest.env`. The archive contains the stripped
`codex`, `codex-code-mode-host`, `codex-responses-api-proxy`, bundled `bwrap`,
`codex-package.json`, and `runtime-files.sha256`. The artifact gate verifies the
same contract before upload; the publisher and public auditors verify it again.

## Post-promotion verification

A workflow-token promotion commit does not recursively schedule other Actions.
Explicitly dispatch the following against final cleaned `main`:

```text
termux-release-channel.yml
termux-governance.yml
termux-control-plane.yml
blocking-ci.yml
```

Release-channel and governance both invoke the same read-only public audit used
before promotion. They independently download public bytes and verify provenance;
they do not trust the publisher's earlier conclusion.

## Completion and cleanup

Do not close the maintenance tracker until live API reads prove every runbook
condition. The final repository must have only the eight permanent workflows, no
temporary maintenance job or script, no staging/gate branch, one completed
tracker, and a GitHub Latest release matching the promoted manifest. Rewrite the
tracker with exact run IDs, source identities, release asset evidence, final
`main`, workflow inventory, and branch inventory before closing it as
`completed`.
