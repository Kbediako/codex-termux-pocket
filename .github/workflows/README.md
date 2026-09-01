# Workflow Strategy

This repository is an Android/Termux-focused Codex CLI fork. Its workflow set is
intentionally small: one routine baseline, three exact-source runtime gates, one
production artifact builder, one release writer, and two independent public
channel auditors.

Agents and maintainers repairing an alpha or publishing a runtime must first read
[`../../docs/termux-release-runbook.md`](../../docs/termux-release-runbook.md).
That runbook is the hard completion contract. Live GitHub state, not a workflow's
intended behaviour or a stale tracker, decides whether a release is complete.

## A layered release system

The release path is a tower of explicit identities rather than a loose sequence
of jobs:

1. **Upstream identity** — an official annotated `rust-v…-alpha…` tag and its
   recursively peeled OpenAI commit.
2. **Runtime identity** — one clean fork `source_sha` containing that upstream
   commit and every maintained Android/Termux patch.
3. **Gate evidence** — five distinct successful workflow runs whose live
   `head_sha` is exactly the runtime identity.
4. **Artifact identity** — one retained production artifact whose metadata,
   archive, internal runtime checksums, package descriptor, and SPDX SBOM all
   identify the same source.
5. **Public identity** — one complete five-asset release whose tag,
   `target_commitish`, API digests, public bytes, attestations, and GitHub Latest
   pointer all agree.
6. **Promoted channel identity** — `scripts/termux/release-manifest.env`, written
   only after the public identity has been anonymously verified.

`.github/scripts/termux_release_control.py` is the machine-executable contract
for layers 3–6. The publisher uses its mutating commands; the release-channel and
governance workflows call the same read-only audit implementation through
`.github/scripts/audit-termux-public-channel.py`. This keeps publication and
independent verification semantically identical without sharing write authority.

## Permanent workflow inventory

- `blocking-ci.yml` (`fork-ci`) runs the broad inexpensive baseline on every pull
  request and `main` push: workflow topology, shell/Python syntax, release-control
  self-tests, locked Cargo metadata, Rust formatting, and dependency policy.
- `termux-control-plane.yml` is the ARM64 contract gate for installer/updater
  helpers, shell tests, release controls, workflow topology, and the complete
  locked dependency graph.
- `termux-linux-sandbox.yml` runs the scoped Linux sandbox suite on public x64
  and ARM64 Ubuntu runners.
- `termux-mobile-artifact.yml` builds, validates, attests, and retains the
  production ARM64 runtime. It is build-only and has no release-write authority.
- `termux-android-emulator.yml` builds its fixture from the triggering source and
  validates it inside the real Termux app on an Android emulator.
- `termux-release-request.yml` is the only release writer.
- `termux-release-channel.yml` independently verifies the promoted public bytes.
- `termux-governance.yml` repeats the public audit, checks force-push observation
  and protection visibility, and also runs daily.

`.github/scripts/validate-termux-workflow-topology.py` enforces this exact
inventory, rejects issue-triggered or temporary maintenance jobs and scripts,
requires all five exact-source gate fields, and ensures no workflow other than
`termux-release-request.yml` can write release state.

## Exact-source pre-publication gates

A run is reusable only when the API proves its workflow path, `head_sha`, final
conclusion, required jobs, and retained artifact are exact. The release request
records all five run IDs:

```text
fork_ci_run_id
control_run_id
sandbox_run_id
artifact_run_id
android_run_id
```

The sandbox run must contain successful `x86_64-unknown-linux-gnu` and
`aarch64-unknown-linux-gnu` jobs. The Android run must contain both fixture-build
and real-Termux jobs. No neighbouring commit, issue-triggered maintenance run,
or expired artifact is acceptable evidence.

## Atomic publication and promotion boundary

The final public asset set is exactly:

```text
codex-termux-aarch64-unknown-linux-musl.tar.gz
codex-termux-sbom.spdx.json
metadata.env
release-manifest.env
SHA256SUMS
```

The publisher re-fetches every gate, validates the retained artifact, attests the
five final files, uploads all five while the release is a draft, and makes that
complete draft public and GitHub Latest in its only release update. It refuses to
repair or retarget a conflicting public release.

Before manifest promotion, the same job acts as an anonymous client. It waits for
GitHub asset digests, downloads all five public files, compares them byte-for-byte
with the attested candidate, validates sizes and digests, strict checksums,
metadata, archive safety and internal checksums, package descriptor, SPDX source
identity, tag resolution, `/releases/latest`, and publisher-signed attestations.
It writes a short audit receipt; promotion revalidates that receipt against live
GitHub state before updating protected `main`.

## Post-promotion verification

Commits made with the workflow `GITHUB_TOKEN` do not recursively trigger other
workflows. After promotion, explicitly dispatch these permanent checks against
final cleaned `main` and wait for live success:

```text
termux-release-channel.yml
termux-governance.yml
termux-control-plane.yml
blocking-ci.yml
```

The tracker closes only after those checks pass and API reads prove the release,
manifest, issue, workflow inventory, and branch inventory satisfy the runbook.
