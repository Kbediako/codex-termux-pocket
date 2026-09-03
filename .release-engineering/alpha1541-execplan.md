# Publish the exact OpenAI Codex 0.154.0-alpha.1 runtime for Termux

This ExecPlan is a living document following the repository root `PLANS.md`. It is deliberately temporary and must be removed before the exact release source is selected.

## Purpose / Big Picture

Update `Kbediako/codex-termux-pocket` to the official `rust-v0.154.0-alpha.1` source while preserving the maintained Android/Termux patch stack. The observable result is one complete five-asset GitHub Latest release whose source, public bytes, checksums, metadata, SPDX SBOM, attestations, tag, updater manifest, and final permanent checks all agree.

## Progress

- [x] Read the release runbook, root and scoped agent instructions, maintainer guide, workflow strategy, native safety boundary, and `PLANS.md`.
- [x] Resolve annotated tag object `93476d33b171c61f08dd44141520d8e7afe6acf1` and recursively peeled OpenAI commit `042534ec1ab2f79c2997e779347d5383832ecb2e`.
- [x] Open maintenance tracker #105 and record the source identities.
- [ ] Run the first exact merge attempt on an isolated staging branch, capture every conflicted path and index stage, and stop rather than guessing.
- [ ] Encode only evidence-reviewed conflict resolutions, refresh Cargo and Bazel locks, and pass supported hosted validation.
- [ ] Remove this plan, helper, and temporary branch-only job; classify retained subjects; prove ancestry; and select one clean `source_sha`.
- [ ] Pass all five exact-source pre-publication gates.
- [ ] Publish only through the permanent release writer and anonymously verify all five public assets before manifest promotion.
- [ ] Pass every permanent post-promotion check on final `main`, clean temporary state, and close #105 with exact live evidence.

## Surprises & Discoveries

- The repository is a standalone mirror rather than a GitHub fork, so connector ref creation cannot directly import the tag-only upstream commit.
- OpenAI's `latest-alpha-cli` branch points to the peeled commit, but a cross-repository PR cannot compute a diff against the standalone mirror.
- Therefore the reviewed branch-only integration job fetches only the pinned official tag and imports its exact Git ancestry without changing protected `main`.

## Decision Log

- Use `automation/alpha1541-integration` as an isolated staging branch.
- Temporarily extend the existing `blocking-ci.yml` only on that branch; do not create a new workflow identity.
- Make the first merge attempt fail closed on every conflict and retain complete evidence before any resolution is added.
- Keep protected `main` fixed at `349ddba31e77bd91a3d58fd90f696cf068f1d57f` until a clean source is selected.

## Outcomes & Retrospective

Pending completion. Evidence will be copied into issue #105 before this file is deleted.

## Context and Orientation

The current promoted runtime is `0.153.0-alpha.6`. The new official tag is `rust-v0.154.0-alpha.1` and its peeled commit is `042534ec1ab2f79c2997e779347d5383832ecb2e`. Five pre-publication workflows must validate one exact fork source. `.github/workflows/termux-release-request.yml` remains the only release writer.

## Plan of Work

The branch-only job squashes the disposable setup and trigger commits, fetches exactly the pinned annotated tag, proves its object and peeled commit, attempts a no-commit merge, and captures the complete conflict state. After reviewed resolution, it refreshes the locked graphs, runs hosted validation, commits a two-parent integration, proves ancestry, and pushes only the staging branch.

Connected GitHub mutations then restore permanent `blocking-ci.yml`, delete disposable files, update release metadata, classify retained subjects, and move `main` only to the clean source. The permanent workflows and executable release contract handle validation, publication, anonymous audit, manifest promotion, and post-promotion checks.
