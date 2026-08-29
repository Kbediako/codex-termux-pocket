# Workflow Strategy

This repository is an Android/Termux-focused Codex CLI fork. Its workflow set is
intentionally limited to checks, artifact builds, device validation, publication,
and public-channel auditing for the supported Termux runtime.

Agents and maintainers repairing alpha CI or publishing a runtime must read
[`../../docs/termux-release-runbook.md`](../../docs/termux-release-runbook.md)
before changing workflow state. That runbook is the hard completion contract and
records the known source-ancestry, retry, generated-script, Actions-recursion,
publication, verification, and cleanup failure modes.

Historical Actions entries can outlive the YAML file that created them. Names
such as `observe-alpha-149-status`, `observe-alpha-149-ci`, and
`Codex CLI Release Detector` may therefore remain visible in old run history,
but they are not retained workflows and cannot start new runs from `main`.
A historical queued run is not automatically harmless: prove its workflow is
absent, its write path is retired, and no current run can race the release. Do
not claim cancellation unless the live API confirms it.

## Actions naming

Each permanent workflow has two deliberately separate identifiers:

- `name` is the stable workflow identity shown in the Actions sidebar and used
  for historical continuity.
- `run-name` is the human-facing title for each individual run.

Every retained workflow declares an explicit `run-name`. Without it, GitHub uses
event-specific text; for a push this is normally the triggering commit message.
That is why older, unrelated runs appeared as `ci: make fork workflows
lightweight`. Those historical titles are retained by GitHub, but future runs
use workflow-specific titles instead. New commits should also use a subject that
describes the actual change rather than reusing that generic phrase.

## Routine checks

- `blocking-ci.yml` (`fork-ci`) runs the broad, relatively inexpensive baseline
  on every pull request and `main` push: workflow topology and YAML, shell and
  Python syntax, locked Cargo metadata, Rust formatting, and dependency policy.
- `termux-control-plane.yml` is the path-filtered ARM64 contract gate for the
  installer, updater, helper tests, locked dependency graph, and Termux workflow
  wiring.
- `termux-linux-sandbox.yml` separately tests the Linux sandbox on public x64 and
  ARM64 Ubuntu runners when its implementation or direct inputs change.

Pre-publication evidence is reusable only when the live run has the exact
selected source in `head_sha`, the expected permanent workflow path, a successful
conclusion, the complete required matrix, and any required retained artifact.
Never substitute a nearby commit or a previous alpha.

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
5. `termux-governance.yml` independently audits the promoted public channel when
   Termux release/governance inputs change, on a daily schedule, or manually.

The final public asset set is exactly:

```text
codex-termux-aarch64-unknown-linux-musl.tar.gz
codex-termux-sbom.spdx.json
metadata.env
release-manifest.env
SHA256SUMS
```

Repository-level release editing intentionally remains enabled. Safety comes
from exact-source validation, staging every final asset before publication,
refusing to replace an existing tag or release, publishing as Latest in the
draft-to-public transaction, and continuously re-verifying the current public
bytes. No post-publication workflow edits an existing release.

Commits made with the workflow `GITHUB_TOKEN` do not recursively trigger another
workflow. After manifest promotion, explicitly dispatch the permanent
release-channel, governance, control-plane, and Fork CI workflows when live run
history does not show those checks on final cleaned `main`.

## Failure signatures that must not be repeated

- A retry is not guaranteed to be a merge commit. Never require `HEAD^2`; prove
  the peeled upstream commit is an ancestor of the selected source.
- Upstream proxy routing may return ownership-bearing control `File`
  descriptors rather than a socket-directory path. Keep descriptors alive and
  adapt the API; do not reinterpret `Vec<File>` as `AbsolutePathBuf`.
- Generated wrapper scripts must use a bootstrap directory distinct from the
  generated transaction directory, and both generated shell and workflow YAML
  must be syntax-checked before dispatch.
- Do not let Actions rewrite workflow YAML or add unapproved one-off workflows.
- Do not infer success from a workflow's expected next step. Re-fetch runs,
  releases, assets, issues, branches, and manifests after every mutation.

## Permanent workflow inventory

- `blocking-ci.yml`
- `termux-control-plane.yml`
- `termux-linux-sandbox.yml`
- `termux-mobile-artifact.yml`
- `termux-android-emulator.yml`
- `termux-release-request.yml`
- `termux-release-channel.yml`
- `termux-governance.yml`

`.github/scripts/validate-termux-workflow-topology.py` enforces this inventory,
requires explicit non-generic run titles, rejects observer/monitor/repair/one-time
workflow names, ensures only the release-request workflow can write a GitHub
release, and prevents the release channel from requiring repository-level release
immutability.
