# Contain unstable Termux kernel sandbox execution

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept current. This plan follows `PLANS.md`.

## Purpose / Big Picture

The maintained Termux runtime must not invoke a restricted Linux kernel sandbox path that has twice coincided with a full Android reboot. Until Android-owned crash evidence can identify and clear the Landlock/seccomp path, restricted commands will fail closed before any kernel sandbox setup. Users can verify that normal Codex startup remains healthy and that an explicit restricted command is refused without executing its payload or rebooting the phone.

## Progress

- [x] (2026-08-12 20:39 UTC) Confirmed a full device reboot from Android uptime and confirmed alpha.10 remained atomically installed afterward.
- [x] (2026-08-12 20:44 UTC) Established that Termux cannot read boot reason, logcat, dmesg, or pstore under the current Android app permissions.
- [x] (2026-08-12 20:49 UTC) Falsified the old `$TMPDIR` denied-write probe: the built-in `:workspace` profile intentionally grants temporary-directory writes.
- [x] (2026-08-12 21:10 UTC) Added an early Termux refusal before Landlock, seccomp, bubblewrap, or payload execution.
- [x] (2026-08-12 21:12 UTC) Replaced the invalid write probe with a fail-closed refusal smoke test and updated operational guidance and patch audit.
- [x] (2026-08-12 21:17 UTC) Passed shell regressions, Bash syntax, ShellCheck, workflow YAML, locked Cargo metadata, diff checks, and Rust formatting; scoped Rust tests were unavailable because `cargo-nextest` is not installed.
- [ ] Build and publish a replacement alpha.10 artifact, install it atomically, and verify the safe refusal on the phone.
- [ ] Pin only the validated replacement release on `main` and mark it latest.

## Surprises & Discoveries

- Observation: the alpha.10 runtime installation completed at 17:52 UTC and Android booted at 17:53 UTC, immediately after the extended installed smoke command began.
  Evidence: `stat` on the active runtime and `uptime -s`, normalized from the phone's UTC+10 local clock.
- Observation: a prior `codex-termux-sandbox-deny-*` file contains `forbidden`, but this does not prove an escape.
  Evidence: `PermissionProfile::workspace_write()` passes `exclude_tmpdir_env_var = false`, so `$TMPDIR` is explicitly writable.
- Observation: current temperatures, available memory, swap, load, and storage are healthy after reboot, but they cannot reconstruct pre-reboot state.
  Evidence: read-only `/proc`, `uptime`, `df`, and exposed thermal-zone snapshots.
- Observation: Android denies all authoritative kernel-crash sources available from unprivileged Termux.
  Evidence: `getprop`, `logcat`, `dmesg`, and `/sys/fs/pstore` return permission errors.
- Observation: repository-wide formatting cannot cover Python or Starlark in this Termux checkout, and the scoped `just test` runner is unavailable.
  Evidence: `just fmt` reports only missing `uv` and `dotslash` after Rust formatting; `just test -p codex-linux-sandbox` stops before compilation because `cargo-nextest` is absent.

## Decision Log

- Decision: Treat the restricted sandbox path as unsafe but not root-caused.
  Rationale: timing repeated at the same boundary, while kernel evidence is unavailable and current health snapshots cannot rule out thermal, memory, firmware, or unrelated Android instability.
  Date/Author: 2026-08-12 / Codex
- Decision: Fail closed before every Termux Linux-sandbox helper path, including proxy/bubblewrap variants.
  Rationale: disabling only Landlock or only seccomp would guess at the cause and leave another kernel-facing path active. Refusal prevents payload execution and is reversible in a later validated artifact.
  Date/Author: 2026-08-12 / Codex
- Decision: Do not pin the already-public `378db3af...` alpha.10 release as the maintained default.
  Rationale: its cloud artifact is valid, but the phone-level restricted-command guardrail is unresolved.
  Date/Author: 2026-08-12 / Codex

## Outcomes & Retrospective

Work is in progress. The alpha.10 source and public artifact are verified, but the maintained default remains unpinned until the containment artifact passes on-device validation.

## Context and Orientation

`codex-rs/linux-sandbox/src/linux_run_main.rs` enters bubblewrap, Landlock, and seccomp enforcement. The Termux fork currently detects `$PREFIX` and selects an in-process Landlock/seccomp fallback because stock Android denies bubblewrap namespaces. `scripts/termux/smoke-test-artifact` owns installed validation. `scripts/termux/tests/run-tests` contains static architecture guards. `docs/termux-mobile-update.md` documents the Android behavior, and `scripts/termux/patch_audit.tsv` classifies fork-only patches.

The active alpha.10 source branch is `release/rust-v0.148.0-alpha.10`. The first public alpha.10 release points to commit `378db3af113b2deb13b299c063365a3d6ec9473d`; it must remain an immutable historical artifact rather than being overwritten.

## Plan of Work

Add a Termux environment check at the start of the Linux sandbox helper and exit with a stable diagnostic before resolving or applying kernel restrictions. Restore the normal permission variables so the now-disabled Termux fallback is not selected. Keep the implementation for non-Termux Linux unchanged.

Change the installed full smoke test to invoke a harmless restricted payload, require the stable refusal and nonzero status, and verify that the payload marker was never created. Retain direct launcher, sidecar, bundled-bubblewrap, DNS, certificate, and browser checks. Update shell static guards, the detailed Termux guide, the patch audit, and this plan.

After local checks pass, commit and push the source branch, dispatch the guarded artifact workflow with a new immutable release tag, and wait for all build/publication gates. Independently verify public checksums, install by exact release tag and SHA, then run the updated installed smoke test. Only after the phone remains stable will the release manifest be pinned on `main` and the new release marked latest.

## Concrete Steps

Run from `/data/data/com.termux/files/home/codex-alpha10-maint` unless noted:

    scripts/termux/tests/run-tests
    shellcheck scripts/termux/* scripts/termux/tests/*
    python -c 'import yaml; yaml.safe_load(open(".github/workflows/termux-mobile-artifact.yml"))'
    cd codex-rs && cargo metadata --locked --format-version=1 >/dev/null
    cd codex-rs && just test -p codex-linux-sandbox
    cd codex-rs && just fmt

The full workspace test suite requires separate user approval under `AGENTS.md` and is not necessary unless the scoped tests expose a shared-crate concern. On Termux, missing `cargo-nextest`, `uv`, or `dotslash` is recorded rather than installed during this stability-sensitive task; the guarded GitHub ARM64 artifact build supplies the authoritative Rust compile gate.

## Validation and Acceptance

On ordinary Linux, existing `codex-linux-sandbox` tests must remain green. On Termux, the updated installed smoke test must report the exact alpha.10 version, verify the launcher and runtime sidecars, receive the expected fail-closed diagnostic from `codex sandbox -P :workspace`, confirm its payload marker does not exist, and return success without rebooting the device.

The published archive, metadata, checksum file, and release manifest must agree on one exact commit and archive SHA-256. `codex-update-alpha check` with that manifest must report the installed runtime current before `main` is updated.

## Idempotence and Recovery

All source work occurs in the isolated alpha.10 worktree. The original checkout and its unrelated documentation edit remain untouched. Git pushes update only the dedicated release branch without force. Release tags are immutable; a failed build is retried from a new commit and receives a new tag. Runtime installation is staged and atomically switches `current`, leaving earlier releases available for rollback.

If the contained smoke test still reboots the phone, do not repeat it. Leave the new release unpinned, preserve uptime and file timestamps, and report that the failure precedes the containment boundary or is unrelated to kernel sandbox setup.

## Artifacts and Notes

Current active runtime after reboot:

    codex-cli 378db3a
    378db3af113b2deb13b299c063365a3d6ec9473d

Current authoritative observation gap: Android system crash logs require privileges unavailable to the Termux app.

## Interfaces and Dependencies

The change uses only `std::env`, `std::path::Path`, and `std::process::exit` in `codex-linux-sandbox`; no dependency or configuration schema change is required. Shell validation continues to depend on Bash, curl, coreutils, proot, and the installed Termux launcher.
