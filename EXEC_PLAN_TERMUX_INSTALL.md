# Make Termux installation artifact-first and recoverable

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept current. This plan follows `PLANS.md`.

## Purpose / Big Picture

A user with a fresh supported Termux installation can paste one command, receive a verified complete Codex runtime, and then run `codex login`. Routine updates never rebase source code or create commits. A maintainer can separately refresh the fork and validate `Cargo.lock`. GitHub Actions produces a traceable runtime bundle containing the main executable, its required code-mode sidecar, bundled bubblewrap, metadata, and checksums. Queued builds can be resumed by run ID without dispatching duplicates.

## Progress

- [x] (2026-08-08 00:00 UTC) Inspected repository instructions, README, Termux scripts, patch audit, workflow, runtime sidecar references, and operational docs.
- [x] (2026-08-08 08:35 UTC) Implemented complete runtime bundle verification, canonical layout installation, atomic activation, Termux launcher checks, and full smoke test.
- [x] (2026-08-08 08:42 UTC) Replaced the ordinary updater with release/run-oriented update, check, wait, and install-run operations; removed all end-user rebase/source-build behavior.
- [x] (2026-08-08 08:46 UTC) Added the idempotent fresh-device installer and automatic origin/upstream topology.
- [x] (2026-08-08 08:49 UTC) Split maintainer alpha rebase and lock refresh into `maintainer-update-alpha`.
- [x] (2026-08-08 08:56 UTC) Added the early CI lockfile gate, full same-revision binary build, checksums, pre-upload content validation, and opt-in public release job.
- [x] (2026-08-08 09:02 UTC) Simplified README and moved recovery and maintainer operations into dedicated docs.
- [x] (2026-08-08 09:12 UTC) Added and passed eight shell regression cases, ShellCheck, Bash syntax, YAML parsing, locked Cargo metadata, Cargo formatting check, and live Termux DNS/TLS probe.
- [x] (2026-08-08 20:10 UTC) Built the exact implementation commit in Actions run 31250598056, passed all artifact gates in 35m48s, downloaded the complete bundle, and independently reverified its checksums and contents.
- [x] (2026-08-08 20:36 UTC) Published and pinned the immutable public release, ran the README installer, and passed the then-current installed artifact/launcher smoke test on the target Termux phone.
- [x] (2026-08-08 21:18 UTC) Traced the stock-Android bubblewrap/Landlock failure, implemented the fail-closed Termux Landlock+seccomp fallback, and proved directly on the phone that the kernel enforces the intended read/write policy.
- [ ] Build and install the musl `O_PATH` follow-up, then require the full command-runner smoke test to pass before publishing it.

## Surprises & Discoveries

- Observation: Repository shell commands initially could not start because neither system `bwrap` nor `codex-resources/bwrap` exists beside the installed Codex executable.
  Evidence: `linux-sandbox/src/launcher.rs` aborted before the first inspection command.
- Observation: `codex-update-alpha` derives `FETCH_REMOTE` from `branch.main.remote` and always rebases before installing.
  Evidence: the fresh-clone `origin` failure and unconditional `git rebase --onto` near the end of the script.
- Observation: the current Actions archive contains only `codex` and has no checksums.
  Evidence: the workflow stages `codex` alone and uploads the tarball plus a minimal `metadata.json`.
- Observation: relying on Bash `set -e` inside a validation function is unsafe when a caller invokes that function in a conditional context.
  Evidence: the first corruption regression appended bytes to the archive but the function continued after `sha256sum` failed; explicit immediate returns fixed it and the regression now passes.
- Observation: repository-wide `just fmt` cannot complete in this Termux checkout because `uv` and `dotslash` are absent.
  Evidence: Rust formatting completed independently with `cargo fmt --all -- --check`; `just fmt` reported only Python SDK, Python scripts, and Bazel/Starlark formatter setup failures.
- Observation: GitHub CLI templates render large numeric `databaseId` values in scientific notation.
  Evidence: live run `31250598056` appeared as `3.1250598056e+10`; updater run IDs are now derived losslessly from the run URL and covered by the queued-run regression.
- Observation: the bundled Linux `bwrap` executable is valid, but a stock Android kernel denies the user/mount namespace operations required by a restricted bubblewrap profile.
  Evidence: the first installed smoke test reached the exact runtime and returned status 182 for `:workspace`. `strace` then showed Android SELinux denying the Landlock fallback's attempt to open `/`, which silently left only `/dev/null` allowed. The replacement uses explicit accessible Android/Termux hierarchies and automatically selects Landlock plus seccomp, failing closed to read-only when nested workspace carve-outs cannot be represented.
- Observation: the first musl fallback artifact still exited 182 while loading a dynamically linked Termux command, even though the same Landlock rules worked from a native Android probe.
  Evidence: syscall comparison showed the native probe opened all 15 roots with `O_PATH`, while the cross-compiled musl helper opened with `O_RDONLY` and Android SELinux rejected `/apex`, `/sys`, and `/storage`. `/apex` contains Android's dynamic-linker runtime. The follow-up opens the fixed internal rule roots with raw `O_PATH` and retains best-effort omission for genuinely unavailable trees.

## Decision Log

- Decision: End-user scripts will be Bash, with an explicit Termux Bash shebang, because reliable JSON parsing, arrays, and strict `pipefail` semantics are useful here. They will not claim POSIX `/bin/sh` compatibility.
  Rationale: Termux supplies Bash and the installer installs/checks it explicitly.
  Date/Author: 2026-08-08 / Codex
- Decision: `origin` remains the Termux fork and `upstream` is fetch-only OpenAI; `remote.pushDefault=origin` and `remote.upstream.pushurl` is disabled.
  Rationale: tag lookup and pushes then have unambiguous, safe roles.
  Date/Author: 2026-08-08 / Codex
- Decision: Ordinary install/update consumes successful CI artifacts and never mutates source history. Rebase logic moves to `maintainer-update-alpha`.
  Rationale: installation cannot require conflict resolution, Git identity, or local commits.
  Date/Author: 2026-08-08 / Codex
- Decision: Artifact identity is the exact workflow `head_sha`; ancestor substitution is removed from the normal path.
  Rationale: security acceptance requires never silently installing a different commit.
  Date/Author: 2026-08-08 / Codex

## Outcomes & Retrospective

The requested artifact/update architecture is implemented and the first exact runtime passed the production ARM workflow. Normal installation is now a verified artifact operation, source-history maintenance is explicit and maintainer-only, exact queued/running Actions runs are recoverable, and the runtime bundle includes every canonical Linux primary binary. A newer, unpromoted fallback artifact exposed an Android `O_PATH` incompatibility; neither it nor the older public release will be presented as satisfying the strengthened restricted-command smoke test until the replacement passes on the phone.

The implementation commit is `804da751873022f224e3be69ee1de7c3f7595bd9`; Actions run `31250598056` completed successfully after 35m48s. Its 391 MiB bundle identifies as `codex-cli 804da75` and has SHA-256 `658b110a7020b66c9280ace776880606f0f6405082cb20f5688843fd9c1f4228`. Those values are pinned in `scripts/termux/release-manifest.env`; no inferred or ancestor artifact is accepted.

## Context and Orientation

`scripts/termux/termux-mobile-lib.sh` owns download, bundle verification, atomic installation, launcher creation, and shared Git/GitHub helpers. `scripts/termux/codex-update-alpha` is the user updater. `scripts/termux/install-codex-termux` is the new bootstrap. `scripts/termux/maintainer-update-alpha` is the source-history maintenance workflow. `scripts/termux/smoke-test-artifact` validates a bundle or installed runtime. `.github/workflows/termux-mobile-artifact.yml` builds the runtime. Shell tests live under `scripts/termux/tests`.

An Actions artifact is a run-scoped downloadable archive. Its runtime bundle contains a nested tar archive, `metadata.env`, and `SHA256SUMS`; verification checks both outer files and each runtime executable before atomic replacement.

## Plan of Work

First, make the shared library verify exact metadata, checksums, architecture, version, and required files, then install a complete staged runtime atomically. Make the launcher set Termux DNS, certificates, browser handoff, runtime resource paths, and a supported bundled-bubblewrap path.

Second, rewrite the updater around explicit `check`, `update`, `wait`, and `install-run` operations. Query `upstream` only for OpenAI tags and query the fork workflow for artifacts. Reuse exact queued, in-progress, or successful matches. Print run IDs/URLs and retain them across timeout recovery.

Third, add a bootstrap script that detects Termux/Play Store builds, installs required packages, safely clones or fast-forwards the dedicated checkout, configures remotes, installs helpers atomically, and invokes the artifact updater. It must leave unrelated and dirty repositories untouched.

Fourth, move rebase mechanics to a maintainer helper. It refuses dirty state, uses `upstream`, performs the rebase explicitly, and runs `cargo metadata --locked` before a maintainer dispatches an artifact.

Finally, change CI to validate `Cargo.lock` before toolchain/cache/build setup, build `codex`, `codex-code-mode-host`, the selected matching runtime sidecars, and bundled `bwrap`, generate metadata/checksums, verify the staged bundle, and upload only validated files. Update user and maintainer docs and add shell fixtures/tests.

## Concrete Steps

All commands run from `/data/data/com.termux/files/home/codex` unless noted.

    bash scripts/termux/tests/run-tests
    shellcheck scripts/termux/* scripts/termux/tests/*
    python -c 'import yaml; yaml.safe_load(open(".github/workflows/termux-mobile-artifact.yml"))'
    cd codex-rs && cargo metadata --locked --format-version=1 --no-deps
    cd codex-rs && just fmt

If tools are unavailable, record the exact missing command and run an equivalent syntax/static check where practical.

## Validation and Acceptance

Tests must prove remote roles are configured without commits, a fork-only `origin` never supplies OpenAI tags, an existing queued/running run is selected rather than dispatched, timeout output carries run recovery data, wrong commit/version/checksum is rejected, missing or non-executable sidecars are rejected, and atomic installation puts `codex-code-mode-host` and `codex-resources/bwrap` where runtime discovery expects them. A fixture command runner must cross the installed wrapper and report a known token.

Workflow validation must establish that the lockfile gate precedes expensive dependency setup, every declared runtime binary is present and executable, metadata reports the executable version and exact SHA, and `sha256sum -c` passes before upload.

## Idempotence and Recovery

The installer updates only its dedicated checkout when it is clean and fast-forwardable. Otherwise it stops with an actionable message. Helper installs use temporary siblings plus `mv`; runtime installation stages a new directory and swaps it into place, retaining the previous runtime until success. Temporary directories are trapped and removed. A timed-out workflow remains active on GitHub and can be resumed with the printed run ID.

## Artifacts and Notes

Initial failure reproduced verbatim: `bubblewrap is unavailable: no system bwrap was found on PATH and no bundled codex-resources/bwrap binary was found next to the Codex executable`.

## Interfaces and Dependencies

End-user dependencies are Termux Bash, Git, curl, tar, gzip, coreutils/sha256sum, certificates, proot, termux-tools, and GitHub CLI only when Actions artifact download requires authentication. CI uses Cargo, Python 3 for deterministic metadata generation, and the existing musl build tooling.
