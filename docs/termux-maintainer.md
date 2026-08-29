# Termux Maintainer Guide

This workflow is intentionally separate from installation on a phone. Only a
maintainer refreshing the fork's patch stack should rebase OpenAI alpha tags.

Before any alpha sync, CI repair, publication, or release takeover, read
[`termux-release-runbook.md`](termux-release-runbook.md) completely. It is the
hard completion contract and records the known failure signatures, exact-source
rules, publication sequence, connected-tooling lessons, and cleanup requirements.

## Refresh the patch stack

Start from a clean `main` checkout and run:

```shell
scripts/termux/maintainer-update-alpha --tag rust-vX.Y.Z-alpha.N
```

The helper configures `origin` as the Termux fork, configures fetch-only
`upstream` as OpenAI, fetches tags from `upstream`, and performs the rebase. It
does not stash, commit, push, force-push, or dispatch CI. Merge conflicts remain
a maintainer responsibility, never an end-user installation step.

After the rebase it runs `cargo metadata --locked --format-version=1 --no-deps`.
If the lockfile is stale, it refreshes resolution with unlocked metadata and
reruns the locked check. Review `codex-rs/Cargo.lock`; when dependency changes
require it, run `just bazel-lock-update` and include `MODULE.bazel.lock`.
Classify every retained Termux commit in `scripts/termux/patch_audit.tsv`.

To validate or refresh only the lockfile after manual conflict work:

```shell
scripts/termux/maintainer-update-alpha --lock-only
```

## Record exact source identity

Peel annotated upstream tags and keep the upstream commit, fork merge commit,
and clean release source separate. Do not infer exact source from the current
branch name or from a presumed merge parent.

```shell
upstream_commit="$(git rev-parse 'refs/tags/rust-vX.Y.Z-alpha.N^{}')"
git merge-base --is-ancestor "$upstream_commit" "$source_sha"
```

A retry may create a single-parent commit even when the initial integration was
a merge. `HEAD^2` is optional diagnostic evidence, not the source-validation
contract. See the runbook for the safe parent check and the historical
`fatal: ambiguous argument 'HEAD^2'` failure.

## Build the runtime

Dispatch `.github/workflows/termux-mobile-artifact.yml` with an exact commit SHA.
The workflow run title is `Termux runtime <SHA>`, which lets the updater and the
formal publisher identify the exact build without dispatching a duplicate.

CI first runs the locked Cargo metadata gate, before APT caches, cross-toolchain
setup, V8 downloads, or compilation. A stale lockfile therefore fails quickly
with the refresh command instead of consuming an ARM build slot.

The build workflow then:

1. Builds and strips `bwrap`, records its SHA-256, and embeds that digest while
   compiling the matching Codex binaries.
2. Builds `codex`, `codex-code-mode-host`, and
   `codex-responses-api-proxy` from the same checkout and target.
3. Writes canonical package metadata plus artifact commit/version metadata.
4. Creates `SHA256SUMS`, extracts the archive again, checks every required file,
   compares executable version to metadata, and runs the bundle smoke test.
5. Generates the SPDX SBOM and provenance attestations for manual exact-ref runs.
6. Uploads the Actions artifact only after all validation passes.

`termux-mobile-artifact.yml` is deliberately build-only. It cannot publish a
GitHub release and has no `contents: write` permission.

## Validate Android, Linux sandbox, CI, and the control plane

The exact runtime source must have successful runs of:

- `.github/workflows/blocking-ci.yml`
- `.github/workflows/termux-control-plane.yml`
- `.github/workflows/termux-linux-sandbox.yml`, including x64 and ARM64
- `.github/workflows/termux-mobile-artifact.yml`
- `.github/workflows/termux-android-emulator.yml`

Do not substitute a successful run from another commit. Record the exact source
SHA and every successful run ID before preparing publication. A run is reusable
only when its live `head_sha`, workflow path, conclusion, matrix jobs, and
retained artifacts all match the selected source.

## Publish a validated runtime

Publication is owned only by `.github/workflows/termux-release-request.yml`.
Write the exact release evidence to `scripts/termux/release-publication.env`:

```text
format_version=1
source_sha=<40-character commit SHA>
release_tag=termux-v<version-or-date>-<source prefix>
expected_package_version=<X.Y.Z-alpha.N>
expected_codex_version=codex-cli <7-character source prefix>
control_run_id=<successful control-plane run>
artifact_run_id=<successful ARM64 artifact run>
android_run_id=<successful Android/Termux run>
```

Review and commit that file on protected `main`. The release workflow then
re-fetches and validates all three exact-source runs, downloads and verifies the
artifact, checks the SBOM and attestations, and stages every final asset in a
draft. Its only release update occurs while that object is still a draft: it
publishes the complete set and designates it GitHub Latest in the same
draft-to-public transaction. It never modifies an already-published release.

The complete public asset set is:

```text
codex-termux-aarch64-unknown-linux-musl.tar.gz
codex-termux-sbom.spdx.json
metadata.env
release-manifest.env
SHA256SUMS
```

Only after anonymous asset downloads, strict checksums, release identity,
attestations, and `/releases/latest` verify does the workflow promote
`scripts/termux/release-manifest.env`. Fresh installs then use the public release
without requiring `gh auth login`.

Repository-level release editing remains enabled by owner policy. The release
channel and governance workflows therefore verify the current public tag,
source, exact asset set, metadata, checksums, attestations, and Latest endpoint
on every relevant run instead of relying on GitHub's immutability setting.

`termux-release-channel.yml` is read-only post-promotion verification.
`termux-governance.yml` independently checks the public channel when the
manifest or release controls change, on its daily schedule, or manually.

Because commits created by the workflow `GITHUB_TOKEN` do not recursively start
new workflows, explicitly dispatch release-channel, governance, control-plane,
and Fork CI checks on final cleaned `main` when the promotion transaction did not
create those runs itself. Do not infer post-promotion success from the publisher.

## Failed or delayed builds

- Queued and running builds may exceed the phone's local wait; they continue on
  GitHub and can be resumed by run ID.
- Do not dispatch another build while an exact queued or running run exists.
- A failed exact run is reported with its URL and is not duplicated
  automatically. Fix the first failing step, then deliberately rerun or dispatch.
- Read the complete failed job log. A workflow can pass compilation and fail
  later in generated release orchestration.
- Never publish or pin a manifest until Fork CI, Linux sandbox, artifact,
  control-plane, and Android/Termux validation have all passed for the same exact
  source.
- Never use the local Android/V8 source build as an end-user fallback.
- Never assume `HEAD^2` exists on a retry.
- Never let Actions rewrite workflow YAML; make workflow edits directly.
- Never repair an already-public release by uploading missing assets or changing
  its source identity.

## Completion and cleanup

Do not close the tracker until the public release, promoted manifest, permanent
post-promotion checks, and final repository topology have all been read back from
GitHub. The tracker body must be rewritten with final evidence rather than left
with stale `state=failed` text.

Final cleanup requires only the permanent workflows, no temporary maintenance
job or script, no staging or gate branch, one completed tracker, and a live
Latest release matching the promoted manifest. The complete checklist and
recommended tracker body are in the release runbook.
