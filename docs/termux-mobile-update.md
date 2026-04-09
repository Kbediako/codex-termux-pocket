# Termux Mobile Update Flow

This fork now supports three install paths for mobile updates:

- `artifact`: install the upstream ARM64 musl alpha binary when the local patch audit says it is safe.
- `remote-artifact`: download a fork-built ARM64 musl artifact from GitHub Actions.
- `source`: fall back to the local low-memory Cargo build.

`codex-update-alpha --mode auto` picks the quickest safe path in that order.

## Why the patch audit exists

This fork still carries Android-specific commits on top of upstream alpha tags.
Some of those commits change runtime behavior on Termux. Installing a raw upstream
binary while those commits are still required would make the installed `codex`
diverge from the checked-out fork in ways that matter on device.

The file [`scripts/termux/patch_audit.tsv`](/data/data/com.termux/files/home/codex/scripts/termux/patch_audit.tsv)
classifies local commits after the current alpha base as:

- `runtime-critical`: upstream artifacts are blocked; use the fork remote artifact or source build.
- `build-only`: only affects local source builds.
- `tooling` / `docs`: helper or documentation changes only.

Unknown local commit subjects are treated as blocking until the audit file is updated.

## Commands

Check whether a newer alpha exists:

```sh
codex-update-alpha --check
```

Use the default safe fast path:

```sh
codex-update-alpha --mode auto
```

Force an upstream release-asset install when the patch audit allows it:

```sh
codex-update-alpha --mode artifact --force
```

Force a local source rebuild:

```sh
codex-update-alpha --mode source --force
```

Build and install a fork artifact for a branch, tag, or commit SHA:

```sh
codex-update-alpha --mode remote-artifact --remote-ref main
codex-update-alpha --mode remote-artifact --remote-ref <commit-sha>
```

Validate an upstream alpha binary without installing it:

```sh
~/codex/scripts/termux/smoke-test-artifact --tag rust-v<latest-alpha>
```

## Remote artifact workflow

The fork workflow [`termux-mobile-artifact.yml`](/data/data/com.termux/files/home/codex/.github/workflows/termux-mobile-artifact.yml)
builds `codex` for `aarch64-unknown-linux-musl` and uploads an Actions artifact named
`codex-termux-aarch64-unknown-linux-musl`.

`codex-update-alpha --mode auto` uses that workflow automatically when:

- the upstream artifact path is blocked by the patch audit, and
- a GitHub fork remote is configured, and
- `gh` is installed and authenticated.

Explicit `--mode remote-artifact --remote-ref ...` dispatches the workflow on the fork
and waits for the matching run before installing the resulting binary.

## Requirements

- Termux `PREFIX` must point at the live Termux install.
- `gh auth status` must be healthy for remote-artifact mode.
- The fork remote should be configured as `branch.main.pushRemote`, or be named `termux-pocket`.

## Recovery

- If `artifact` mode fails in `auto`, the helper falls back to `source`.
- If `remote-artifact` mode fails in `auto`, the helper falls back to `source`.
- The helper validates candidate binaries before replacing `$PREFIX/bin/codex`.
- Dirty working trees are auto-stashed before the rebase/update path and restored afterward.
