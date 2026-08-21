# Termux Maintainer Guide

This workflow is intentionally separate from installation on a phone. Only a
maintainer refreshing the fork's patch stack should rebase OpenAI alpha tags.

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

## Validate Android and the control plane

The exact runtime source must also have successful runs of:

- `.github/workflows/termux-control-plane.yml`
- `.github/workflows/termux-android-emulator.yml`

Do not substitute a successful run from another commit. Record the exact source
SHA and the three successful run IDs before preparing publication.

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

Only after anonymous asset downloads, checksums, release identity, and
`/releases/latest` verify does the workflow promote
`scripts/termux/release-manifest.env`. Fresh installs then use the public release
without requiring `gh auth login`.

Repository-level release editing remains enabled by owner policy. The release
channel and governance workflows therefore verify the current public tag,
source, exact asset set, metadata, checksums, attestations, and Latest endpoint
on every relevant run instead of relying on GitHub's immutability setting.

`termux-release-channel.yml` is read-only post-promotion verification.
`termux-governance-audit.yml` independently checks the public channel when the
manifest or release controls change, on its daily schedule, or manually.

## Failed or delayed builds

- Queued and running builds may exceed the phone's local wait; they continue on
  GitHub and can be resumed by run ID.
- Do not dispatch another build while an exact queued or running run exists.
- A failed exact run is reported with its URL and is not duplicated
  automatically. Fix the first failing step, then deliberately rerun or dispatch.
- Never publish or pin a manifest until the artifact, control-plane, and
  Android/Termux validations have all passed for the same exact source.
- Never use the local Android/V8 source build as an end-user fallback.
