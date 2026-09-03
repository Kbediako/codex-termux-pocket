# Publish the exact OpenAI Codex 0.153.0-alpha.6 runtime for Termux

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept current. It follows the repository root `PLANS.md` and is deliberately temporary: it must be removed before the exact release source is selected.

## Purpose / Big Picture

Users of `Kbediako/codex-termux-pocket` should receive a GitHub Latest Termux runtime built from the newest official OpenAI Codex Rust alpha, with the maintained Android/Termux patch stack preserved. The observable result is a complete five-asset `0.153.0-alpha.6` release whose source, checksums, metadata, SPDX SBOM, attestations, tag, `target_commitish`, public downloads, updater manifest, and final permanent CI checks all agree.

## Progress

- [x] (2026-09-03 02:21 UTC) Read the release runbook, root and scoped agent instructions, maintainer guide, workflow strategy, native safety boundary, and `PLANS.md`.
- [x] (2026-09-03 02:21 UTC) Inventory live main, releases, branches, PRs, issues, workflows, rulesets, and Actions state.
- [x] (2026-09-03 02:21 UTC) Resolve `rust-v0.153.0-alpha.6`, annotated tag object `22a9fdf5f01d606eff192aacb93bc3107688450f`, peeled commit `e8b3253fed5aeef7e914441bc3b73b3b0a718b51`, and workspace package version `0.153.0-alpha.6`.
- [x] (2026-09-03) Created one audited staging commit containing this plan, the integration helper, the temporary `blocking-ci.yml` job, and its patch classification.
- [x] (2026-09-03) Captured the complete sole `codex-rs/Cargo.toml` conflict and resolved only its reviewed workspace-version block from alpha.4 to the official alpha.6 value.
- [x] (2026-09-03) Refreshed locked Cargo and Bazel dependency graphs as required and passed supported hosted pre-source validation.
- [ ] Remove this plan, the helper, and the temporary job; classify retained subjects; prove upstream ancestry; select one clean `source_sha`.
- [ ] Run exact-source Fork CI, control-plane, Linux x64 and ARM64 sandbox, production ARM64 artifact, and native Android/Termux gates.
- [ ] Submit the permanent publication request only after every gate and retained artifact are live-successful and exact.
- [ ] Let the permanent publisher create the complete five-asset draft, publish it once as Latest, anonymously verify it, and only then promote the manifest.
- [ ] Dispatch and verify release-channel, governance, control-plane, and Fork CI on final cleaned main.
- [ ] Remove all staging state, update and close issue #103 with live evidence, and confirm no open duplicate tracker remains.

## Surprises & Discoveries

- Observation: OpenAI published stable `0.153.0` after alpha.6, but the newest official tag matching the repository’s requested Rust-alpha channel is `rust-v0.153.0-alpha.6`; no `rust-v0.154*` tag exists at takeover.
  Evidence: the upstream matching-ref inventory contains alpha.1 through alpha.6, and the `rust-v0.154` prefix is empty.
- Observation: historical queued run `32212182486` remains visible from a deleted temporary workflow identity.
  Evidence: live Actions state reports no current in-progress run and only that 19 August ghost. The runbook allows it only while its file/identity/write path remain absent and non-raceable.

- Observation: the exact alpha.6 merge had one conflict only, in the `[workspace.package]` version line of `codex-rs/Cargo.toml`; index stage 1 was `0.0.0`, the fork side was `0.153.0-alpha.4`, and upstream was `0.153.0-alpha.6`.
  Evidence: failed integration run 33707625806 and retained artifact 9875788825 captured the combined diff and all three index stages before the fail-closed retry encoded the resolution.

## Decision Log

- Decision: merge the recursively peeled alpha.6 commit into an isolated staging branch instead of force-rebasing protected `main`.
  Rationale: this preserves published history, allows exact conflict evidence, and permits a normal fast-forward of protected main after temporary controls are removed.
  Date/Author: 2026-09-03 / implementing release engineer.
- Decision: temporarily extend the existing permanent `blocking-ci.yml` only on the staging branch, rather than creating a new workflow identity or allowing Actions to edit workflow YAML.
  Rationale: it obeys the repository’s release-authority boundaries and is removable before source selection.
  Date/Author: 2026-09-03 / implementing release engineer.
- Decision: no conflict resolution is encoded in the first integration attempt.
  Rationale: the runbook requires complete failed-job evidence before editing; a conflict, if any, must be inspected rather than guessed from the prior alpha.4 update.
  Date/Author: 2026-09-03 / implementing release engineer.

## Outcomes & Retrospective

The exact alpha.6 commit was integrated after one evidence-reviewed version conflict and passed hosted pre-source validation. Cleanup and exact-source selection remain; this file must be removed before release gate evidence is accepted.

## Context and Orientation

The current protected `main` is `8410d9fafca4add1b44dde9ef8c268e70a22747e`, which promotes Termux `0.153.0-alpha.4`. The exact upstream alpha.6 commit is `e8b3253fed5aeef7e914441bc3b73b3b0a718b51`. `scripts/termux/patch_audit.tsv` classifies every retained fork subject. `.github/workflows/blocking-ci.yml`, `termux-control-plane.yml`, `termux-linux-sandbox.yml`, `termux-mobile-artifact.yml`, and `termux-android-emulator.yml` are the five pre-publication gates. `.github/workflows/termux-release-request.yml` is the only release writer. `termux-release-channel.yml` and `termux-governance.yml` independently re-audit public state after manifest promotion.

A `source_sha` is the exact clean fork commit used by all five release gates. It is not the annotated tag object, peeled upstream commit, integration merge, publication request commit, or final promoted-main commit. A release is complete only after live GitHub state proves all identities and checks in `docs/termux-release-runbook.md`.

## Plan of Work

On `automation/alpha1536-integration`, squash the temporary setup into one classified staging commit. Fetch only the official alpha.6 tag from OpenAI, verify its annotated object and recursively peeled commit, and merge that commit without committing. If Git reports conflicts, capture `git status`, the conflicted path list, combined diff, and index stages 1–3; upload the evidence and stop. If the merge is clean, append the integration subject to `patch_audit.tsv`, refresh Cargo and Bazel locks as required, run the Termux helper tests and release-control checks, format Rust, commit the merge, and push only the staging branch.

After a successful merge, use connected GitHub mutations—not Actions—to restore permanent `blocking-ci.yml`, delete this plan and the integration helper, and update `patch_audit.tsv` in one clean source-selection commit. Prove the peeled upstream commit is an ancestor of that source, fast-forward `main`, and run every gate on exactly that SHA. Do not move main again until the five gate set and retained artifact are complete.

When all gates are successful, update `scripts/termux/release-publication.env` with the exact source and run IDs. The permanent publisher must validate, attest, upload all five files while draft, publish once as Latest, anonymously download and verify the public release, and promote the updater manifest only after the audit. Finally, explicitly dispatch the four permanent post-promotion workflows on cleaned main, remove any staging branch, replace issue #103 with final evidence, and close it completed.

## Concrete Steps

The temporary hosted integration job will execute from the repository root:

    git fetch --force --no-tags upstream refs/tags/rust-v0.153.0-alpha.6:refs/tags/rust-v0.153.0-alpha.6
    git rev-parse refs/tags/rust-v0.153.0-alpha.6
    git rev-parse refs/tags/rust-v0.153.0-alpha.6^{}
    git merge --no-ff --no-commit e8b3253fed5aeef7e914441bc3b73b3b0a718b51
    cargo metadata --locked --format-version=1
    just bazel-lock-update
    PREFIX=/data/data/com.termux/files/usr TERMUX_APK_RELEASE=F_DROID bash scripts/termux/tests/run-tests
    python3 .github/scripts/termux_release_control.py self-test
    cd codex-rs && cargo fmt --all && cargo fmt --all -- --check
    git merge-base --is-ancestor e8b3253fed5aeef7e914441bc3b73b3b0a718b51 HEAD

Permanent workflows will then be dispatched or observed according to `docs/termux-maintainer.md`; each run must report the exact selected source SHA.

## Validation and Acceptance

Acceptance requires all ten definition-of-done clauses in `docs/termux-release-runbook.md`. In particular: five exact-source successful pre-publication runs; one unexpired retained production artifact; a five-file public non-draft release made Latest in its initial transaction; anonymous byte, digest, checksum, metadata, archive, SBOM, tag, target, Latest, and attestation verification; post-audit manifest promotion; four explicit successful permanent post-promotion runs on final cleaned main; one completed issue; only permanent workflows; only intended branches; and no raceable temporary orchestration.

## Idempotence and Recovery

The staging branch starts at the recorded current main and is never used as a release source until temporary files are removed. The integration helper refuses an unexpected branch head, tag object, peeled commit, package version, dirty worktree, or remote branch race. A failed merge leaves complete evidence and does not push an integrated source. A repaired attempt must either use the same exact upstream identity with an evidence-based fix or choose a new source and restart all gates. Public conflicting releases are never mutated; the permanent publisher may only reuse an already-complete exact Latest release or delete a safe abandoned draft.

## Artifacts and Notes

Maintenance tracker: issue #103.

Pinned upstream identity:

    upstream_tag=rust-v0.153.0-alpha.6
    upstream_tag_object=22a9fdf5f01d606eff192aacb93bc3107688450f
    upstream_commit=e8b3253fed5aeef7e914441bc3b73b3b0a718b51
    package_version=0.153.0-alpha.6

## Interfaces and Dependencies

The transaction depends on Git, Bash, Python 3, Ruby YAML parsing, Rust 1.95.0 with rustfmt, Cargo, Just, Bazelisk through the repository setup action, GitHub CLI, the eight permanent Actions workflows, and `.github/scripts/termux_release_control.py`. No new runtime dependency or release writer is introduced.