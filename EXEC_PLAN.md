# Speed Up Termux Mobile Codex Install

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept current. If PLANS.md exists in this repo, this plan follows it.


## Purpose / Big Picture

Reduce the end-to-end mobile install/update time for Codex on Termux, with the immediate focus on the supported fast path driven by `scripts/termux/codex-update-alpha`. Today the documented remote-artifact path takes about 20 minutes on this device. The outcome should be a measurably faster install path without regressing the Termux runtime bridge or ChatGPT-login behavior on Android.


## Progress

- [x] (2026-04-16 23:28) Collected the current benchmark and helper/workflow entry points from `docs/termux-mobile-update.md`, `scripts/termux/codex-update-alpha`, and `.github/workflows/termux-mobile-artifact.yml`.
- [x] (2026-04-16 23:43) Baselined recent workflow durations and isolated the dominant time sink in the current remote-artifact path.
- [x] (2026-04-16 23:47) Deliberated on candidate speedups with subagents and chose the highest-leverage safe set.
- [x] (2026-04-17 00:44) Implemented workflow/helper optimizations: tighter helper flow, cache reuse for Cargo home and musl tools, and remote artifact reuse for exact-SHA and runtime-equivalent commits.
- [x] (2026-04-17 00:50) Validated the new path against the old baseline with fresh-build and reuse benchmarks on device.
- [x] (2026-04-17 02:25) Deliberated on true cold-build acceleration with subagents and constrained the safe zone to workflow-only changes plus `patch_audit.tsv`.
- [x] (2026-04-17 02:34) Implemented a first cold-build experiment in `termux-mobile-artifact.yml`: musl-safe `sccache` enablement plus timing uploads and cache stats.
- [ ] (2026-04-17 02:34) Validate whether the new workflow materially reduces fresh-run build time on the fork, and fall back to selective `target/` reuse if it does not.


## Surprises & Discoveries

- Observation: The documented supported path is already artifact-first; the remaining ~20 minute cost is not the old on-device source fallback.
  Evidence: `docs/termux-mobile-update.md` states the remote-artifact install completes in about 20 minutes while the local source path took 5997 seconds and still failed.

- Observation: `codex-update-alpha` currently waits on the GitHub Actions workflow `termux-mobile-artifact.yml` and polls every 15 seconds; any major speedup likely comes from reducing remote build latency, not helper polling alone.
  Evidence: `scripts/termux/codex-update-alpha` uses `wait_for_remote_run*()` with `sleep 15`.

- Observation: Recent successful `termux-mobile-artifact` runs spend about 93-94% of total job time inside `Build Codex for Termux`.
  Evidence: Run `24492815727` took about 20m14s total with `Build Codex for Termux` running about 18m50s; run `24294222401` took about 18m48s total with `Build Codex for Termux` running about 17m47s.

- Observation: The helper has smaller but still real avoidable latency in remote-artifact mode: a fixed post-dispatch sleep and 15 second polling loops.
  Evidence: `scripts/termux/codex-update-alpha` has an explicit `sleep 5` after dispatch and uses `sleep 15` in both remote workflow wait functions.

- Observation: Cargo-home and musl-tools cache reuse only shaved seconds, not minutes. The warmed workflow run still spent about 18m49s in `Build Codex for Termux` and finished in about 20m07s overall.
  Evidence: Warmed run `24540772912` restored both caches successfully, but its compile time remained essentially flat relative to cold run `24539677807`.

- Observation: Reusing an already-successful remote artifact for the same SHA collapses repeat `--mode remote-artifact --remote-ref <sha>` installs to about 20.654 seconds end to end on this device.
  Evidence: Local benchmark after adding artifact reuse logic completed in `20.654` seconds and installed `codex-cli 77881cd` without dispatching a new workflow.

- Observation: Runtime-equivalent ancestor reuse also collapses tooling-only follow-up installs to about 22.151 seconds end to end on this device.
  Evidence: Local benchmark against `e88346898340c06edd5ab36f3c6f49ab16d450a9` reused successful run `24540772912` from `77881cd57e2e9b4e3280e5baebcec12f5f664fec` because the newer tail was tooling-only, then completed in `22.151` seconds.

- Observation: The repo already disables `sccache` on musl in `rust-ci-full`, but the disabling reason is wrapper-slot conflict, not a documented musl incompatibility.
  Evidence: `rust-ci-full.yml` enables `RUSTC_WRAPPER=sccache`, then clears it for musl before installing the musl `rustc-ubsan-wrapper`.

- Observation: Subagent research split on the best cold-build experiment: `sccache` is the lower-risk first step, while selective `target/` reuse likely has a higher ceiling but materially larger cache-size and staleness risk.
  Evidence: the musl-wrapper feasibility stream found a safe combined `RUSTC_WRAPPER` shape for `sccache`, while the alternatives stream argued for `target/` reuse due to native/build-script output reuse.


## Decision Log

- Decision: Treat the remote-artifact path as the optimization target first.
  Rationale: It is the supported fast path on Termux today; the local source path remains experimental and still fails on the Android-targeted V8 link.
  Date/Author: 2026-04-16 / Codex

- Decision: Keep runtime-critical Termux/login behavior out of scope for optimization changes unless we can prove a speedup requires touching it.
  Rationale: The user explicitly asked not to regress key fixes such as ChatGPT login on Android.
  Date/Author: 2026-04-16 / Codex

- Decision: Prioritize workflow-side cache reuse for hermetic Cargo home data and musl tool bootstrap state, then land smaller helper-side latency cleanup in parallel.
  Rationale: The measured bottleneck is the remote Rust build step, while helper-side waits are smaller but cheap wins. Both changes are tooling-scoped and can be implemented without touching runtime-critical Termux behavior.
  Date/Author: 2026-04-16 / Codex

- Decision: Prefer artifact reuse over deeper compile caching as the next optimization step when the target SHA already has a successful artifact, or when newer commits are classified as tooling/docs/build-only.
  Rationale: Warmed dependency caches did not materially reduce compile time, while exact-SHA artifact reuse cut repeat install time from minutes to seconds. The patch-audit classifications already provide the safety boundary for reusing runtime-equivalent artifacts.
  Date/Author: 2026-04-17 / Codex

- Decision: For true cold-build acceleration, try musl-safe `sccache` in `termux-mobile-artifact.yml` before selective `target/` reuse.
  Rationale: `sccache` stays inside existing repo patterns, has lower cache-bloat/staleness risk than `target/` caching, and can be added without leaving the workflow-only safe zone. If it does not materially move the build step, `target/` reuse becomes the next experiment.
  Date/Author: 2026-04-17 / Codex


## Outcomes & Retrospective

The deeper compile bottleneck did not move much with dependency/tool bootstrap caching alone: fresh remote builds still land around 20 minutes and still spend almost all of that time in the actual Rust build step. The meaningful win came from not rebuilding when the runtime payload is already known-good. Exact-SHA artifact reuse cut repeat installs to about 20.654 seconds, and runtime-equivalent ancestor reuse cut tooling-only tip installs to about 22.151 seconds. That met the first-phase goal without touching the Termux runtime bridge or Android ChatGPT-login behavior.

The second phase is now in flight: keep the safe zone to workflow-only changes, enable musl-safe `sccache` in the fork artifact workflow, and benchmark whether compiler-output reuse lowers the ~18m49s build step on fresh runners. If it does not, the next experiment is selective `target/` reuse for the `aarch64-unknown-linux-musl` release path.


## Context and Orientation

The current mobile update/install entry point is `scripts/termux/codex-update-alpha`. In `--mode auto`, it chooses among three paths:

- `artifact`: upstream release artifact when the patch audit says the local patch stack is safe.
- `remote-artifact`: fork-built GitHub Actions artifact for `aarch64-unknown-linux-musl`.
- `source`: experimental on-device Cargo build, disabled by default on Termux.

Relevant files:

- `/data/data/com.termux/files/home/codex/scripts/termux/codex-update-alpha`
- `/data/data/com.termux/files/home/codex/.github/workflows/termux-mobile-artifact.yml`
- `/data/data/com.termux/files/home/codex/docs/termux-mobile-update.md`
- `/data/data/com.termux/files/home/codex/scripts/termux/patch_audit.tsv`
- `/data/data/com.termux/files/home/codex/scripts/termux/termux-mobile-lib.sh`

Terms:

- “remote-artifact path” means: rebase local fork to the selected alpha, push `main` to the fork, wait for `termux-mobile-artifact.yml`, download the produced tarball, validate it, and install it into Termux.
- “runtime bridge” means the launcher and proot/browser-handoff behavior used by the installed Termux binary.


## Plan of Work

First, measure where the current remote-artifact time is going: helper-side polling/waiting, workflow scheduling, dependency setup, or the actual Rust build. Second, compare safe optimization candidates such as workflow caching, runner changes, helper-side reuse of existing artifacts, and tighter polling/dispatch logic. Third, implement the smallest set of changes that plausibly reduces end-to-end time without altering runtime-critical Termux behavior. Finally, validate by triggering the supported path again and comparing elapsed time against the current ~20 minute baseline.


## Concrete Steps

1. Inspect recent `termux-mobile-artifact` workflow runs and extract job timing for setup, dependency installation, and `Build Codex for Termux`.
2. Inspect helper-side waits in `codex-update-alpha`, especially dispatch, polling, artifact download, and verification.
3. Deliberate on candidate speedups with subagents, including build-cache options and helper-side reuse.
4. Edit the selected files with `apply_patch`.
5. Run targeted validation:
   - `git diff --check`
   - workflow/job inspection for the new run(s)
   - any targeted script smoke checks that are cheap and safe
6. Update this ExecPlan with actual timings and outcomes.


## Validation and Acceptance

Success means:

- the supported mobile install path is faster than the current documented ~20 minute remote-artifact baseline, or we can show a concrete reduction in the dominant step with new measured timings;
- the helper still selects the same safe install modes and preserves patch-audit protections;
- no change regresses the Termux runtime bridge or the assumptions behind Android ChatGPT login;
- the changed workflow/script path completes or advances further/faster with no new failures.


## Idempotence and Recovery

Workflow-only and helper-only changes should be safe to retry. If a new optimization fails, revert just the affected workflow/helper patch and keep the runtime bridge/auth patches intact. Any new commit subject added to the fork patch stack must be classified in `scripts/termux/patch_audit.tsv` so future updates do not get blocked as unknown.


## Artifacts and Notes

- Baseline from docs: remote-artifact about 20 minutes; local source fallback about 5997 seconds and failed.
- Measured fresh-build runs after the helper/workflow speedups:
  - `24539677807`: about 20m23s total, about 18m51s in `Build Codex for Termux`
  - `24540772912`: about 20m02s total, about 18m49s in `Build Codex for Termux`
- Measured reuse-path installs after artifact reuse:
  - exact-SHA reuse: `20.654` seconds
  - runtime-equivalent ancestor reuse: `22.151` seconds
- Current remote artifact workflow: `termux-mobile-artifact.yml`.
- Current helper polling cadence: 15 second loops in `wait_for_remote_run()` and `wait_for_remote_run_since()`.


## Interfaces and Dependencies

- GitHub Actions workflow dispatch/download through `gh`
- Termux install helpers in `scripts/termux/termux-mobile-lib.sh`
- `actions/checkout`, `dtolnay/rust-toolchain`, `mlugg/setup-zig`, and the musl build tooling script
- `patch_audit.tsv` classifications for any new fork-only optimization commits
