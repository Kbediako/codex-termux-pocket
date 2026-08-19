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
  when Rust or native build inputs change. It remains manually dispatchable for
  exact refs; formal channel publication is owned by the release-request flow.

## Release and device validation

- `termux-android-emulator.yml` is not routine CI. It runs manually or when a
  device-validation request changes, so a flaky or still-in-development Android
  scenario does not make ordinary pushes red.
- `termux-release-request.yml` reads the explicit exact-source evidence in
  `scripts/termux/release-publication.env`, revalidates the control-plane,
  production ARM64, and native Android runs, stages every final asset on a draft,
  then publishes that complete draft as GitHub Latest in one transaction.
- `termux-release-channel.yml` is verification-only. It checks the promoted
  manifest, release identity, asset set, anonymous downloads, checksums, and
  GitHub's Latest endpoint; it never mutates a published release.
- `termux-governance-audit.yml` independently checks the promoted public release
  identity, checksums, tag, and governance state.

Inherited Windows, macOS, Bazel, SDK, Python, upstream release, contributor-bot,
and OpenAI-internal workflows have been removed from this fork.
