# Workflow Strategy

This repository is an Android/Termux-focused Codex CLI fork. The workflow set
is intentionally limited to checks and release operations that protect the
supported Termux runtime.

## Routine checks

- `blocking-ci.yml` (`fork-ci`) emits one compact `Termux fork checks` job for
  workflow and script syntax, locked Cargo metadata, Rust formatting, and
  dependency policy.
- `termux-control-plane.yml` validates the installer, updater, artifact
  contract, shell helpers, and workflow wiring when those inputs change.
- `termux-linux-sandbox.yml` tests the Linux sandbox on x86_64 and ARM64 when
  the sandbox or its direct build inputs change.
- `termux-mobile-artifact.yml` builds the supported ARM64 Termux runtime only
  when Rust or native build inputs change. It also remains manually
  dispatchable for exact refs and releases.

## Release and device validation

- `termux-android-emulator.yml` is not routine CI. It runs manually or when a
  Termux release request is committed, so a flaky or still-in-development
  Android device scenario does not make ordinary pushes red.
- `termux-release-request.yml` publishes only after the exact ARM64 artifact
  and release-gated Android validation succeed.
- `termux-governance-audit.yml` checks the promoted public release identity,
  checksums, and governance state.

Inherited Windows, macOS, Bazel, SDK, Python, upstream release, contributor-bot,
and OpenAI-internal workflows have been removed from this fork.
