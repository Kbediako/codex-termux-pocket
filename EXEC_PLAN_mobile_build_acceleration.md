# Make Mobile Codex Updates Fast with Artifact-First Termux Installs

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept current. If PLANS.md exists in this repo, this plan follows it.

## Purpose / Big Picture

Termux updates to the latest Codex alpha should stop depending on repeated on-device Rust release builds for the common case. A user on this Samsung/Termux device should be able to move from one upstream alpha to the next by downloading a published ARM64 artifact, verifying it locally, and keeping source builds only for fork-specific changes or emergency fallback.

The observable user outcome is:

- `codex-update-alpha` finishes without invoking Cargo when an upstream alpha artifact is compatible with Termux.
- The helper reports the exact alpha tag, install source (`release-asset` or `source-build`), and verification output.
- Fork-only runtime changes are handled explicitly instead of being silently lost.
- Source-build fallback remains available and benchmarked.

## Progress

- [x] (2026-04-09 13:25 AEST) Read the current Termux updater and self-update paths in `scripts/termux/codex-update-alpha` and `codex-rs/cli/src/main.rs`.
- [x] (2026-04-09 13:25 AEST) Verified that the local fork is still based on `rust-v0.118.0-alpha.3` with local Termux commits on top.
- [x] (2026-04-09 13:25 AEST) Verified live upstream alpha channels and assets; validation ended with `rust-v0.119.0-alpha.28` as the latest tag returned by `codex-update-alpha --check`.
- [x] (2026-04-09 13:25 AEST) Executed published ARM64 musl binaries on this Termux device, including a final smoke validation of `rust-v0.119.0-alpha.28`.
- [x] (2026-04-09 14:00 AEST) Audited fork-only commits into `scripts/termux/patch_audit.tsv` with runtime-critical, build-only, tooling, and docs classifications.
- [x] (2026-04-09 14:00 AEST) Added `scripts/termux/smoke-test-artifact` and shared artifact/install helpers in `scripts/termux/termux-mobile-lib.sh`.
- [x] (2026-04-09 14:00 AEST) Extended `codex-update-alpha` with `artifact`, `source`, `remote-artifact`, and `auto` modes, with upstream-artifact and remote-artifact fallback logic.
- [x] (2026-04-09 14:00 AEST) Added `.github/workflows/termux-mobile-artifact.yml` so the fork can build Linux ARM64 musl artifacts off-device for Termux installs.
- [x] (2026-04-10 02:20 AEST) Benchmarked the remaining source fallback paths and codified the result: Termux source builds now fail fast by default, with remote artifacts as the supported fork/mobile path.

## Surprises & Discoveries

- Observation: upstream already publishes the exact ARM64 Linux artifacts needed for Termux alpha updates.
  Evidence: during validation, `codex-update-alpha --check` resolved `rust-v0.119.0-alpha.28`, and upstream release assets for that series include `codex-aarch64-unknown-linux-musl.tar.gz` and `install.sh`.

- Observation: the published ARM64 musl binary inside the alpha npm tarball runs on this device.
  Evidence: `scripts/termux/smoke-test-artifact --tag rust-v0.119.0-alpha.28` returned `codex-cli 0.119.0-alpha.28`.

- Observation: the current fork still carries local Termux/runtime patches, so artifact-only updates cannot replace the source path blindly.
  Evidence: `git log origin/main..main` contains Android-specific commits such as `Termux: use shared C++ runtime for Android audio build`, `arg0: tolerate unsupported file locks on Android`, and `tui: silence Android clipboard warnings`.

- Observation: the original local source path had two earlier failure modes before reaching the final linker.
  Evidence: an unlocked `cargo install --path cli --root "$PREFIX" --force` ran for 5997 seconds before failing in `temporal_rs` / `icu_calendar` version drift, and a locked rerun without overrides failed earlier because `v8` tried to download the missing upstream Android archive `librusty_v8_release_aarch64-linux-android.a.gz`.

- Observation: even the repaired locked source path is still not shippable on Termux.
  Evidence: a locked rerun with the pinned OpenAI musl archive and binding pair reached the final `codex` binary link and then failed with unresolved `bcmp` and `__errno_location` symbols from `libv8` while targeting Android.

- Observation: the CLI build graph is large enough that "just rebuild the CLI" is still expensive on-device.
  Evidence: `cargo tree -p codex-cli --prefix none | wc -l` returned `3222`, and `cargo tree -p codex-cli -i v8 --target aarch64-linux-android` shows `v8 -> codex-code-mode -> codex-core -> codex-cli`.

- Observation: npm alpha platform delivery is exposed through `@openai/codex` dist-tags, not a standalone `@openai/codex-linux-arm64` package.
  Evidence: `https://registry.npmjs.org/@openai%2fcodex-linux-arm64` returned 404, while `https://registry.npmjs.org/@openai%2fcodex` exposes `alpha`, `alpha-linux-arm64`, and related dist-tags.

## Decision Log

- Decision: prioritize an artifact-first Termux updater before deeper local Rust build optimization.
  Rationale: the fastest build is no local build; upstream already publishes compatible ARM64 artifacts that run on this device.
  Date/Author: 2026-04-09 / Codex

- Decision: keep a fork-aware source fallback instead of replacing the existing helper outright.
  Rationale: this fork still carries Android-specific runtime and build fixes that may not yet be represented in upstream binaries.
  Date/Author: 2026-04-09 / Codex

- Decision: use GitHub release assets as the primary installation source for Termux, with npm registry metadata only for channel discovery if needed.
  Rationale: GitHub releases already host the install script, raw binary tarballs, and npm tarballs for the exact alpha tag.
  Date/Author: 2026-04-09 / Codex

- Decision: treat remote branch artifacts as a first-class path for fork/mobile development.
  Rationale: the repo already uses `cargo-chef`, sccache, musl tooling, and V8 overrides in CI; Termux should consume those outputs rather than reproducing them locally for every fork change.
  Date/Author: 2026-04-09 / Codex

- Decision: disable Termux source fallback by default and require explicit opt-in for future retries.
  Rationale: benchmarking is now complete, and the remaining blocker is a deterministic final-link V8/ABI mismatch rather than a missing performance tweak. Remote artifacts are the supported path for fork/mobile updates.
  Date/Author: 2026-04-10 / Codex

## Outcomes & Retrospective

Implementation is now in place for the artifact-first mobile update path. The biggest shift is that the primary mobile problem is no longer "how do we make Cargo slightly less painful on Android" but "how do we safely adopt published ARM64 alpha artifacts without dropping fork-specific fixes."

Completed work:

- `codex-update-alpha` now chooses between upstream release assets, fork remote artifacts, and source builds.
- local patch audit data is recorded in `scripts/termux/patch_audit.tsv`
- remote fork builds can produce a Termux-ready artifact through `.github/workflows/termux-mobile-artifact.yml`
- validation scripts and docs are in place

Remaining work:

- upstream or replace the Termux/V8 source-build story if local Android-targeted Cargo builds need to become supported again

## Context and Orientation

Relevant repo files and what they currently do:

- `/data/data/com.termux/files/home/codex/scripts/termux/codex-update-alpha`
  Rebase local `main` onto the newest `rust-v*-alpha.*` tag, push the fork, then choose between upstream release assets, fork remote artifacts, or an explicit opt-in source retry.

- `/data/data/com.termux/files/home/codex/codex-rs/cli/src/main.rs`
  Implements `codex self-update` for Termux; it currently does a local `git fetch`, `git pull --ff-only`, then refuses the known-bad Android Cargo rebuild unless `CODEX_TERMUX_ALLOW_SOURCE_FALLBACK=1` is set.

- `/data/data/com.termux/files/home/codex/scripts/install/install.sh`
  Generic binary installer that already knows how to download Linux ARM64 musl Codex release artifacts.

- `/data/data/com.termux/files/home/codex/.github/workflows/rust-release.yml`
  Publishes release assets and npm tarballs for stable and alpha builds, including Linux ARM64.

- `/data/data/com.termux/files/home/codex/.github/workflows/rust-ci.yml`
  Already uses CI-side build acceleration (`cargo-chef`, sccache where possible, musl setup, and V8 overrides). Those optimizations currently help runners, not Termux.

- `/data/data/com.termux/files/home/codex/third_party/v8/README.md`
  Documents the musl `rusty_v8` release-pair model that previously blocked local Termux builds.

Current state at research time:

- Local fork describe string: `rust-v0.118.0-alpha.3-13-gcff294e82`
- Latest upstream alpha seen during implementation: `rust-v0.119.0-alpha.28`
- This changed during the same work session, which is why helper mode selection must resolve live tags instead of relying on repo-local state.

Termux-specific constraint:

- This fork is ahead of upstream with Android fixes. The updater must never silently swap in an upstream artifact if that would remove required local runtime behavior.

## Plan of Work

Phase 1 is compatibility and decision logic, not installer churn.

1. Audit fork-only commits.
   Create a short machine-readable manifest in the repo that classifies each local Termux commit as one of:
   - `runtime-critical`: upstream alpha binaries cannot replace the source-built fork until this lands upstream or is retired.
   - `build-only`: only affects local source builds and does not block upstream artifact installs.
   - `tooling/docs`: helper scripts, docs, or AGENTS changes that do not affect the shipped binary.

   Expected files:
   - `/data/data/com.termux/files/home/codex/scripts/termux/patch_audit.tsv`
   - `/data/data/com.termux/files/home/codex/docs/termux-mobile-update.md` for the human-readable explanation

2. Add a Termux artifact smoke suite.
   Implement a script that downloads a specified ARM64 alpha artifact into a temp directory, runs a small non-interactive smoke suite, and records pass/fail plus version.

   Expected files:
   - `/data/data/com.termux/files/home/codex/scripts/termux/smoke-test-artifact`
   - optional supporting shell helpers under `/data/data/com.termux/files/home/codex/scripts/termux/`

   Initial smoke scope should stay simple and restartable:
   - `codex --version`
   - `codex --help`
   - `codex exec --help`
   - `codex completion zsh` or another non-network subcommand

3. Extend the updater into explicit modes.
   Evolve `codex-update-alpha` into:
   - `--mode artifact`
   - `--mode source`
   - `--mode auto`
   - `--mode remote-artifact`

   `auto` should:
   - resolve the latest alpha tag
   - consult the patch audit
   - run the artifact smoke suite
   - install the published ARM64 artifact only when the patch audit and smoke suite say it is safe
   - otherwise prefer the fork remote artifact path and refuse the local Termux source build by default unless explicitly opted in

   The helper output must always state:
   - selected alpha tag
   - install mode used
   - installed version
   - repo describe string when source mode is used
   - whether the repo is dirty

4. Add remote branch artifact support for fork work.
   Create a lightweight workflow that can build Linux ARM64 musl artifacts for a branch or commit on the fork and publish them as downloadable artifacts or prerelease assets. Then extend the Termux helper to install by branch or commit SHA.

   Expected files:
   - a new workflow under `/data/data/com.termux/files/home/codex/.github/workflows/`
   - helper updates in `/data/data/com.termux/files/home/codex/scripts/termux/codex-update-alpha`
   - documentation in `/data/data/com.termux/files/home/codex/README.md` or `/data/data/com.termux/files/home/codex/docs/termux-mobile-update.md`

   This path is the answer for:
   - local runtime patches not yet upstreamed
   - branch testing on mobile
   - avoiding multi-hour on-device rebuilds after every fork change

5. Benchmark and tighten the source fallback.
   Only after the artifact path exists, benchmark the remaining source path and decide whether to:
   - keep an explicit experimental retry path
   - disable the default local Cargo rebuild if the final Android link is still broken
   - preserve the low-memory flags and musl V8 override pair for future diagnostics
   - redirect normal users to remote artifacts when local runtime patches still matter

   The source path is no longer the mainline experience, so use it only where the data says it is still worth retrying.

## Concrete Steps

All commands below assume `cwd=/data/data/com.termux/files/home/codex` unless stated otherwise.

1. Record current baseline and fork delta.

   git status --short
   git describe --tags --always --dirty
   git log --oneline origin/main..main

2. Verify current upstream alpha release assets.

   curl -fsSL 'https://api.github.com/repos/openai/codex/releases?per_page=5'
   curl -fsSL https://api.github.com/repos/openai/codex/releases?per_page=5

   Expected result:
   - latest release object is the newest `rust-v*-alpha.*`
   - assets include `codex-aarch64-unknown-linux-musl.tar.gz`
   - the release includes an ARM64 Linux artifact for the resolved alpha

3. Verify current npm alpha channel metadata.

   curl -fsSL https://registry.npmjs.org/@openai%2fcodex

   Expected result:
   - `dist-tags.alpha` points at the newest upstream alpha
   - `dist-tags.alpha-linux-arm64` points at the Linux ARM64 companion tag

4. Reproduce the successful Termux artifact execution.

   tmpdir=$(mktemp -d)
    cd "$tmpdir"
   ~/codex/scripts/termux/smoke-test-artifact --tag rust-v<latest-alpha>

   Expected result:
   - `codex-cli <latest-alpha-version>`

5. Measure source-path complexity before changing it.

   cd /data/data/com.termux/files/home/codex/codex-rs
   cargo tree -p codex-cli --prefix none | wc -l
   cargo tree -p codex-cli -i v8 --target aarch64-linux-android

   Expected result:
   - dependency tree output is large
   - V8 reaches the CLI through `codex-code-mode` and `codex-core`

## Validation and Acceptance

This plan is successful when all of the following are true:

1. Upstream alpha consumer path
   - On a clean Termux device with no required fork runtime patches, `codex-update-alpha --mode auto` installs the latest alpha without running Cargo.
   - The helper prints the exact installed alpha tag and `codex --version`.

2. Fork-aware safety
   - When local runtime-critical patches are still required, `codex-update-alpha --mode auto` refuses the artifact path and explains why before using the fork remote-artifact path or an explicitly opted-in source retry.
   - No required Termux runtime behavior is silently dropped.

3. Remote branch path
   - A fork branch or commit can produce Linux ARM64 musl artifacts in CI.
   - Termux can install that artifact by branch or SHA and verify the resulting version.

4. Source fallback is handled explicitly
   - `codex-update-alpha --mode source` no longer silently burns hours on a known-bad Termux build by default.
   - The helper explains the final V8/ABI linker blocker and points users to `remote-artifact` unless they opt in to `CODEX_TERMUX_ALLOW_SOURCE_FALLBACK=1`.
   - Benchmarks for artifact mode vs source mode are recorded in docs.

5. Documentation
   - README or dedicated Termux docs explain when each mode is used.
   - The recovery path is explicit.

## Idempotence and Recovery

- Artifact mode must install into a temp directory first and only overwrite the live binary after the smoke suite passes.
- Source mode keeps the current stash/rebase handling from `codex-update-alpha`.
- If artifact validation fails, the helper must:
  - leave the existing installed Codex binary untouched
  - print the failed tag and validation step
  - prefer the remote-artifact path, and otherwise point users at the explicit `CODEX_TERMUX_ALLOW_SOURCE_FALLBACK=1` retry
- If a remote branch artifact is unavailable, the helper must fail closed and tell the user whether to retry later or use `--mode source` with explicit opt-in.
- Any benchmark scripts should write timestamped output files so repeated runs do not destroy earlier evidence.

## Artifacts and Notes

Short evidence captured during research:

    git describe --tags --always --dirty
    rust-v0.118.0-alpha.3-13-gcff294e82

    git log --oneline origin/main..main | sed -n '1,8p'
    cff294e82 termux: streamline alpha update flow
    5b843559a docs: refresh Termux README guidance
    b5fcfe864 Termux: use shared C++ runtime for Android audio build
    4c0f65702 arg0: tolerate unsupported file locks on Android
    f433ca242 tui: silence Android clipboard warnings

    PREFIX=/data/data/com.termux/files/usr ./scripts/termux/codex-update-alpha --check
    Latest alpha tag: rust-v0.119.0-alpha.28
    Current base tag: rust-v0.118.0-alpha.3
    Update available.

    PREFIX=/data/data/com.termux/files/usr ./scripts/termux/smoke-test-artifact --tag rust-v0.119.0-alpha.28
    codex-cli 0.119.0-alpha.28

    cd codex-rs && cargo tree -p codex-cli --prefix none | wc -l
    3222

## Interfaces and Dependencies

Core repo interfaces this work will touch:

- shell helper interface in `/data/data/com.termux/files/home/codex/scripts/termux/codex-update-alpha`
- Termux self-update flow in `/data/data/com.termux/files/home/codex/codex-rs/cli/src/main.rs`
- release artifact production in `/data/data/com.termux/files/home/codex/.github/workflows/rust-release.yml`
- possible new branch-artifact workflow in `/data/data/com.termux/files/home/codex/.github/workflows/`
- release/install documentation in `/data/data/com.termux/files/home/codex/README.md` or `/data/data/com.termux/files/home/codex/docs/`

External systems and assumptions:

- GitHub Releases for `openai/codex`
- npm registry metadata for `@openai/codex`
- Linux ARM64 musl artifacts remain published for alpha releases
- Termux can execute the published statically linked ARM64 musl Codex binary
