# Complete and repair the Codex Termux 0.153.0-alpha.6 release

This ExecPlan is a living record. It must be updated while the release is repaired and removed from the final exact-source tree after its evidence is copied into maintenance issue #103.

## Purpose

Publish the already-audited OpenAI `rust-v0.153.0-alpha.6` integration through the repository’s permanent release system, correct the broken release controls, and leave the repository in the runbook’s fully clean definition-of-done state.

## Progress

- [x] Read `docs/termux-release-runbook.md`, root and scoped `AGENTS.md`, workflow strategy, maintainer guide, and `PLANS.md`.
- [x] Re-inventory live GitHub state and confirm the previous completion claim was false.
- [x] Confirm official annotated tag object `22a9fdf5f01d606eff192aacb93bc3107688450f` recursively peels to OpenAI commit `e8b3253fed5aeef7e914441bc3b73b3b0a718b51` and that no later `0.153` or `0.154` Rust alpha exists.
- [x] Inspect complete logs for the three failed runs: two malformed publisher-YAML failures and one unauthenticated public-audit rate-limit failure.
- [x] Confirm cleaned integration commit `880ac959e512eae94fac9ab644c53a0b205c08fd` contains the peeled upstream commit and no temporary integration helper or workflow.
- [ ] Create one explicit merge resolution that preserves both histories while selecting the cleaned alpha.6 tree, removes every takeover/bootstrap file, restores the proven permanent publisher, authenticates GitHub API metadata reads, and classifies every retained commit subject.
- [ ] Prove the resulting source is clean, contains the exact upstream commit, and has exactly the documented permanent eight-workflow inventory.
- [ ] Run Fork CI, control-plane, Linux x64 and ARM64 sandbox, production ARM64 artifact, and native Android/Termux gates on one exact source SHA.
- [ ] Confirm the production artifact is retained and internally valid; write the validated publication request only after all five gates succeed.
- [ ] Publish exactly five assets atomically through `.github/workflows/termux-release-request.yml` as GitHub Latest.
- [ ] Anonymously verify public bytes, sizes, SHA-256 digests, strict `SHA256SUMS`, archive safety, metadata, SPDX source identity, tag resolution, Latest pointer, and attestations before manifest promotion.
- [ ] Explicitly dispatch release-channel, governance, control-plane, and Fork CI against final cleaned `main` and require live success.
- [ ] Update and close maintenance issue #103 as `completed`; remove this plan and the integration branch; prove no open issue/PR, no temporary path, no in-progress run, and only `main` remains.

## Findings

The previous automation confused a staged integration with completion. It also embedded an unindented shell heredoc inside workflow YAML, making the publisher unparsable, and the shared public-audit code used an unauthenticated GitHub API helper despite a token-bearing client already being available. The repair therefore restores the last proven publisher rather than retaining the oversized broken orchestration, and narrows the code fix to authenticated API metadata while keeping release-asset downloads public.

## Decision log

- Use a two-parent Git commit with `main` and the cleaned integration head as parents because GitHub reports the ordinary PR merge as conflicted. Build its tree from the cleaned integration tree and explicitly overlay only reviewed permanent repairs. This preserves history without force-pushing and excludes disposable bootstrap files from the exact source.
- Keep post-promotion dispatch and tracker closure under maintainer control for this transaction instead of expanding release-write workflow authority. The permanent publisher remains the sole release writer.
- Do not accept any prior or neighbouring run as evidence; every gate must report the exact final source SHA and required successful jobs.
