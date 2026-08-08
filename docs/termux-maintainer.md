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

To validate/refresh only the lockfile after manual conflict work:

```shell
scripts/termux/maintainer-update-alpha --lock-only
```

## Build and publish the runtime

Dispatch `.github/workflows/termux-mobile-artifact.yml` with an exact commit SHA.
The workflow run title is `Termux runtime <SHA>`, which lets the updater reuse a
queued or running match without dispatching a duplicate.

CI first runs the locked Cargo metadata gate, before APT caches, cross-toolchain
setup, V8 downloads, or compilation. A stale lockfile therefore fails quickly
with the refresh command instead of consuming an ARM build slot.

The workflow then:

1. Builds and strips `bwrap`, records its SHA-256, and embeds that digest while
   compiling the matching Codex binaries.
2. Builds `codex`, `codex-code-mode-host`, and
   `codex-responses-api-proxy` from the same checkout and target.
3. Writes canonical package metadata plus artifact commit/version metadata.
4. Creates `SHA256SUMS`, extracts the archive again, checks every required file,
   compares executable version to metadata, and runs the bundle smoke test.
5. Uploads the Actions artifact only after all validation passes.

For a public no-login end-user release, set `publish_release=true` and provide a
new immutable `termux-v...` release tag. The separate publication job alone has
`contents: write`; the build retains `contents: read`. Publication refuses to
overwrite an existing release.

The release includes a generated `release-manifest.env`. Copy its exact values
into `scripts/termux/release-manifest.env`, review them, and commit that small
pointer update. Fresh installs then use curl against the public release and do
not need `gh auth login`.

## Failed or delayed builds

- Queued and running builds may exceed the phone's local wait; they continue on
  GitHub and can be resumed by run ID.
- Do not dispatch another build while an exact queued/running run exists.
- A failed exact run is reported with its URL and is not duplicated
  automatically. Fix the first failing step, then deliberately rerun or dispatch.
- Never publish or pin a manifest until the workflow's artifact-content
  validation has passed.
- Never use the local Android/V8 source build as an end-user fallback.
