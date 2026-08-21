# Workflow Strategy

This repository is an Android/Termux-focused Codex CLI fork. Its workflow set is
intentionally limited to checks, artifact builds, device validation, publication,
and public-channel auditing for the supported Termux runtime.

Historical Actions entries can outlive the YAML file that created them. Names
such as `observe-alpha-149-status`, `observe-alpha-149-ci`, and
`Codex CLI Release Detector` may therefore remain visible in old run history,
but they are not retained workflows and cannot start new runs from `main`.

## Routine checks

- `blocking-ci.yml` (`fork-ci`) runs the broad, relatively inexpensive baseline
  on every pull request and `main` push: workflow topology and YAML, shell and
  Python syntax, locked Cargo metadata, Rust formatting, and dependency policy.
- `termux-control-plane.yml` is the path-filtered ARM64 contract gate for the
  installer, updater, helper tests, locked dependency graph, and Termux workflow
  wiring.
- `termux-linux-sandbox.yml` separately tests the Linux sandbox on public x64 and
  ARM64 Ubuntu runners when its implementation or direct inputs change.

## Artifact and device validation

- `termux-mobile-artifact.yml` builds, validates, attests, and uploads the
  production ARM64 runtime. It is build-only and has no release-write authority.
- `termux-android-emulator.yml` is the expensive native Android/Termux gate. It
  runs for release requests, changes to the device gate itself, or a deliberate
  manual dispatch rather than ordinary housekeeping pushes.

## Release path

1. `termux-release-request.yml` is the only release publisher. It reads the exact
   source, release identity, and successful validation run IDs from
   `scripts/termux/release-publication.env`.
2. It re-verifies the control-plane, ARM64 artifact, Android/Termux evidence,
   checksums, SBOM, attestations, and final assets. It uploads the complete set to
   a draft, then publishes that draft as GitHub Latest in one transaction.
3. It anonymously byte-verifies the public assets and `/releases/latest` before
   promoting `scripts/termux/release-manifest.env`.
4. `termux-release-channel.yml` is read-only current-state verification. It
   proves that the promoted manifest still identifies a complete GitHub Latest
   release with the expected source, assets, metadata, checksums, and attestations.
5. `termux-governance-audit.yml` independently audits the promoted public channel
   when Termux release/governance inputs change, on a daily schedule, or manually.

Repository-level release editing intentionally remains enabled. Safety comes
from exact-source validation, staging every final asset before publication,
refusing to replace an existing tag or release, publishing as Latest in the
draft-to-public transaction, and continuously re-verifying the current public
bytes. No post-publication workflow edits an existing release.

## Permanent workflow inventory

- `blocking-ci.yml`
- `termux-control-plane.yml`
- `termux-linux-sandbox.yml`
- `termux-mobile-artifact.yml`
- `termux-android-emulator.yml`
- `termux-release-request.yml`
- `termux-release-channel.yml`
- `termux-governance-audit.yml`

`.github/scripts/validate-termux-workflow-topology.py` enforces this inventory,
rejects observer/monitor/repair/one-time workflow names, ensures only the
release-request workflow can write a GitHub release, and prevents the release
channel from requiring repository-level release immutability.
