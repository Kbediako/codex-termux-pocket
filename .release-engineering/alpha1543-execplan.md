# Publish the exact OpenAI Codex 0.154.0-alpha.3 runtime for Termux

This ExecPlan is a living document following the repository root `PLANS.md`. It is deliberately temporary and must be removed before the exact release source is selected.

## Purpose / Big Picture

Update `Kbediako/codex-termux-pocket` to the official `rust-v0.154.0-alpha.3` source while preserving the maintained Android/Termux patch stack. The observable result is one complete five-asset GitHub Latest release whose source, public bytes, checksums, metadata, SPDX SBOM, attestations, tag, updater manifest, and final permanent checks all agree.

## Progress

- [x] Read the release runbook, root and scoped agent instructions, maintainer guide, workflow strategy, and `PLANS.md`.
- [x] Resolve annotated tag object `b20bd605db8cecf55db6d370a4cb71842bfdfa32` and recursively peeled OpenAI commit `d58a64e690508a752c6a5a466ea752808849b7e2`.
- [x] Open maintenance tracker #107 and record the source identities.
- [ ] Run the first exact merge attempt on an isolated staging branch, capture every conflicted path and index stage, and stop rather than guessing.
- [ ] Encode only evidence-reviewed conflict resolutions, refresh Cargo and Bazel locks, and pass supported hosted validation.
- [ ] Remove this plan, helper, and temporary branch-only job; classify retained subjects; prove ancestry; and select one clean `source_sha`.
- [ ] Pass all five exact-source pre-publication gates.
- [ ] Publish only through the permanent release writer and anonymously verify all five public assets before manifest promotion.
- [ ] Pass every permanent post-promotion check on final `main`, clean temporary state, and close #107 with exact live evidence.

## Surprises & Discoveries

- The repository is a standalone mirror rather than a GitHub fork, so the upstream tag's objects must be imported by a repository Action before a two-parent merge commit can exist in this object database.
- The exact alpha.3 release commit is not a descendant of the alpha.1 release commit; the pinned annotated tag, peeled commit, and merge ancestry therefore remain the authoritative identities.
- The reviewed branch-only integration job fetches only the pinned official tag and imports its exact Git ancestry without changing protected `main`.

## Decision Log

- Use `automation/alpha1543-integration` as an isolated staging branch.
- Temporarily extend the existing `blocking-ci.yml` only on that branch; do not create a new workflow identity.
- Make the first merge attempt fail closed on every conflict and retain complete evidence before any resolution is added.
- Keep protected `main` fixed at `8dcfde2341f272517f427bac090279508ae6825f` until a clean source is selected.

## Outcomes & Retrospective

Pending completion. Evidence will be copied into issue #107 before this file is deleted.

## Context and Orientation

The current promoted runtime is `0.154.0-alpha.1`. The new official tag is `rust-v0.154.0-alpha.3` and its peeled commit is `d58a64e690508a752c6a5a466ea752808849b7e2`. Five pre-publication workflows must validate one exact fork source. `.github/workflows/termux-release-request.yml` remains the only release writer.

## Plan of Work

The branch-only job squashes the disposable setup and trigger commits, fetches exactly the pinned annotated tag, proves its object and peeled commit, attempts a no-commit merge, and captures the complete conflict state. After reviewed resolution, it refreshes the locked graphs, runs hosted validation, commits a two-parent integration, proves ancestry, and pushes only the staging branch.

Connected GitHub mutations then restore permanent `blocking-ci.yml`, delete disposable files, update release metadata, classify retained subjects, and move `main` only to the clean source. The permanent workflows and executable release contract handle validation, publication, anonymous audit, manifest promotion, and post-promotion checks.
