# Workflow Strategy

This repository is an Android/Termux-focused Codex CLI fork. Normal pushes and
pull requests intentionally avoid inherited Windows, macOS, SDK, Bazel,
OpenAI-internal, and upstream publishing matrices.

## Routine checks

- `blocking-ci.yml` (`fork-ci`) emits one compact `Termux fork checks` job. It
  validates workflow YAML, Bash and Python helper syntax, the locked Cargo
  metadata, Rust formatting, and Cargo dependency policy.
- `termux-control-plane.yml` runs focused Termux helper, installer, manifest,
  workflow-contract, shellcheck, and artifact-flow regression tests when the
  Termux control plane changes.
- `termux-linux-sandbox.yml` runs the hosted Linux sandbox test matrix only when
  the sandbox or its direct build inputs change.

## Native and release validation

- `termux-mobile-artifact.yml` builds and verifies the supported
  `aarch64-unknown-linux-musl` runtime from the triggering source.
- `termux-android-emulator.yml` builds the exact-source x86_64-musl surrogate
  and exercises the official Termux debug app in an Android emulator.
- `termux-governance-audit.yml` verifies the promoted public release identity,
  checksums, and governance state.

Inherited reusable or manually dispatched workflows can remain as upstream
reference machinery, but they are not called by routine fork CI. Branch
protection or repository rulesets should require only checks that this focused
workflow set actually emits.
