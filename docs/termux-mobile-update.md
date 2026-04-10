# Termux Mobile Update Flow

This fork now supports three install paths for mobile updates:

- `artifact`: install the upstream ARM64 musl alpha binary when the local patch audit says it is safe.
- `remote-artifact`: download a fork-built ARM64 musl artifact from GitHub Actions.
- `source`: retry the local low-memory Cargo build only when explicitly opted in.

`codex-update-alpha --mode auto` picks the quickest safe path in that order, but the source path is disabled by default on Termux because the Android-targeted Cargo build still fails at the final V8 link.

## Why the patch audit exists

This fork still carries Android-specific commits on top of upstream alpha tags.
Some of those commits change runtime behavior on Termux. Installing a raw upstream
binary while those commits are still required would make the installed `codex`
diverge from the checked-out fork in ways that matter on device.

The file [`scripts/termux/patch_audit.tsv`](/data/data/com.termux/files/home/codex/scripts/termux/patch_audit.tsv)
classifies local commits after the current alpha base as:

- `runtime-critical`: upstream artifacts are blocked; use the fork remote artifact.
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

Retry the local source rebuild experimentally:

```sh
CODEX_TERMUX_ALLOW_SOURCE_FALLBACK=1 codex-update-alpha --mode source --force
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

## Measured improvement

On this device, the new supported path already reduced alpha update/install time materially:

- the remote-artifact install completed in about 20 minutes
- the benchmarked local `cargo install` path took 5997 seconds and still failed

Upstream release-asset installs should be faster again when the patch audit allows them.

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

- If `artifact` mode fails in `auto`, the helper falls back to `remote-artifact` when the fork workflow is available.
- If no artifact path is usable, the helper refuses the local source build by default and tells you to use `remote-artifact` or opt into `CODEX_TERMUX_ALLOW_SOURCE_FALLBACK=1`.
- The helper validates candidate binaries before replacing `$PREFIX/bin/codex`.
- Dirty working trees are auto-stashed before the rebase/update path and restored afterward.

## Source fallback status

A fresh benchmark on 2026-04-10 established the current boundary:

- unlocked local `cargo install --path cli` drifted to incompatible crate versions after about 5997 seconds
- `--locked` without V8 overrides failed earlier because upstream no longer publishes the Android-targeted `rusty_v8` archive URL that `v8` expects
- `--locked` with the pinned OpenAI musl archive and binding pair reached the final `codex` binary link, then failed on unresolved V8/ABI symbols (`bcmp`, `__errno_location`) against the Android target

That means the source path is still useful as an experimental diagnostic tool, but it is no longer part of the default fast-path story for Termux.
