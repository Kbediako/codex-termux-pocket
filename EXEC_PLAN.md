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
- [x] (2026-04-17 02:42) Ran the first `sccache` build on the fork; the workflow reached cache save/stats but failed in `Build Codex for Termux` due to a musl UBSan preload regression while loading `sqlx_macros`.
- [x] (2026-04-17 02:50) Adjusted the `sccache` experiment to move the musl UBSan preload to the build environment and force a fresh `sccache` server start before the build.
- [x] (2026-04-17 03:18) Rejected the musl `sccache` path after the second run failed on the same proc-macro UBSan symbol resolution and redirected the workflow to selective release-target caching with the known-good direct rustc wrapper.
- [x] (2026-04-17 03:41) Restored correctness with the direct musl wrapper, validated the updater/artifact contract against run `24544435578`, and reproduced the first warm-cache failure on `rusty_v8`.
- [x] (2026-04-17 04:10) Re-ran the warm-cache experiment after adding `target/${TARGET}/release/gn_out/obj`; the rerun succeeded and cut `Build Codex for Termux` from about `18m55s` to about `13m49s`.
- [x] (2026-04-21 03:10 UTC) Re-baselined the current fork after the successful `rust-v0.123.0-alpha.2` remote-artifact install and confirmed the dominant cost is still the remote `Build Codex for Termux` step.
- [x] (2026-04-21 03:26 UTC) Validated the next workflow-only iteration with three subagents and narrowed it to APT archive reuse, release-cache key hygiene, and a controlled x64 runner benchmark while keeping the Android runtime/auth path untouched.
- [x] (2026-04-21 06:13 UTC) Validated the release-cache-key change on the real arm shipping path: run `24702957227` restored both release caches across a workflow-only edit and held `Build Codex for Termux` at about `13m50s`, then run `24706188602` stayed green at about `14m07s`.
- [x] (2026-04-21 06:14 UTC) Closed the hosted x64 benchmark as non-viable for this workflow after three benchmark attempts exposed host/target env leaks and finally a fundamental linker mismatch (`musl-gcc` on hosted x64 cannot link the `aarch64-unknown-linux-musl` CRT objects).
- [x] (2026-04-21 07:07 UTC) Reopened hosted x64 only as a dispatch-only zig-linker benchmark: restore an opt-in x64 runner path, keep push builds on arm, and validate whether the existing Zig wrapper could replace the missing hosted x64 aarch64 musl linker without touching Android runtime/auth behavior.
- [x] (2026-04-21 07:13 UTC) Closed the zig-linker x64 spike and reverted it from head after two setup-time `libcap` failures on hosted x64 (`_makenames` host exec format under target `CC`, then `__CAP_BITS` compile failures under the zig fallback). The benchmark never reached Cargo and did not justify further workflow churn.


## Surprises & Discoveries

- Observation: The documented supported path is already artifact-first; the remaining ~20 minute cost is not the old on-device source fallback.
  Evidence: `docs/termux-mobile-update.md` states the remote-artifact install completes in about 20 minutes while the local source path took 5997 seconds and still failed.

- Observation: `codex-update-alpha` now polls every 10 seconds, so helper-side latency is smaller than the older plan text implied; the dominant win still has to come from remote build time.
  Evidence: `scripts/termux/codex-update-alpha` currently uses `sleep 10` in both `wait_for_remote_run()` and `wait_for_remote_run_since()`.

- Observation: Recent successful `termux-mobile-artifact` runs spend about 93-94% of total job time inside `Build Codex for Termux`.
  Evidence: Run `24492815727` took about 20m14s total with `Build Codex for Termux` running about 18m50s; run `24294222401` took about 18m48s total with `Build Codex for Termux` running about 17m47s.

- Observation: The helper has already captured the main local-side win through exact-SHA and runtime-equivalent artifact reuse; after that, only tens of seconds remain in polling/download/install overhead.
  Evidence: reuse-path installs complete in about `20.654` to `22.151` seconds, while the latest successful remote workflow still spent `1257` of `1369` seconds inside `Build Codex for Termux`.

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

- Observation: The first `sccache`-enabled fork run seeded a real compiler cache but failed because the musl UBSan preload no longer reached the rustc proc-macro load path.
  Evidence: run `24543089388` compiled until `sqlx`, then failed with `libsqlx_macros-...so: undefined symbol: __ubsan_handle_type_mismatch_v1`; `sccache --show-stats` reported `807` Rust misses, `0` hits, and `639 MiB` cached.

- Observation: The second `sccache` attempt proved that the cache itself works for Rust crates, but it still failed on the same musl proc-macro load path even after moving `LD_PRELOAD` into the build environment.
  Evidence: run `24543767684` reached a `96.50%` Rust hit rate and shortened `Build Codex for Termux` to about `2m44s` before failing again on `libsqlx_macros-...so: undefined symbol: __ubsan_handle_type_mismatch_v1`.

- Observation: The repo’s own musl CI already treats `sccache` and the musl UBSan wrapper as mutually exclusive, which is a stronger signal than the raw cache-hit numbers.
  Evidence: `rust-ci-full.yml` enables `RUSTC_WRAPPER=sccache`, then explicitly clears it for musl before installing the direct `rustc-ubsan-wrapper`.

- Observation: The first release-target cache attempt was correct for a cold run and for artifact installation, but the warm rerun failed because the `rusty_v8` native archive lives under `target/${TARGET}/release/gn_out/obj`, which was outside the cached path set.
  Evidence: push run `24544435578` succeeded and the updater reinstalled its artifact in `19.802` seconds, but warm rerun `24545305708` restored both host and target caches and then failed in about `54` seconds with `could not find native static library 'rusty_v8'`; the `v8` build logic downloads the prebuilt archive into `build_dir()/gn_out/obj`.

- Observation: the current `termux-mobile-artifact.yml` path no longer wires `sccache`; the active optimizations are cargo-home cache reuse, musl-tools cache reuse, selective release caches, and helper-side remote artifact reuse.
  Evidence: the workflow restores Cargo home, musl tools, host release outputs, and target release outputs before `cargo build`, but there are no `Install sccache`, `Configure sccache backend`, or `RUSTC_WRAPPER=sccache` steps in the current file.

- Observation: After adding `target/${TARGET}/release/gn_out/obj`, the warm rerun succeeded and materially shortened the compile step, so the release-target cache path is already paying off for repeat builds on the same dependency graph.
  Evidence: push run `24545827350` built `Build Codex for Termux` in about `18m55s`, while warm rerun `24546776031` on the same SHA restored both release caches and finished `Build Codex for Termux` in about `13m49s`.

- Observation: the hosted x64 zig-linker spike failed before Cargo and exposed `libcap` as another blocker on this path. First the build used the target compiler for the `_makenames` host helper and hit an `Exec format error`; after forcing `BUILD_CC` back to the host compiler, the zig cross compile still failed in `cap_alloc.c` with `__CAP_BITS` undeclared.
  Evidence: dispatch runs `24709051877` and `24709162889` both failed in `Install musl build tools`, first at `./_makenames`, then at `cap_alloc.c:28:10: error: use of undeclared identifier '__CAP_BITS'`.

- Observation: The current release-cache key still includes the whole workflow file, so any workflow-only edit cold-soaks the warm release caches even when the dependency graph and build semantics stay the same.
  Evidence: `termux-mobile-artifact.yml` hashes the workflow file itself into `dependency_tooling_hash`, and the same workflow already showed a roughly `5` minute compile-step improvement once its release caches were allowed to warm.

- Observation: With musl `sccache` rejected and the helper already optimized, the remaining cold-build upside is in runner class and setup trimming, not another new cache mechanism.
  Evidence: the latest successful cold build run `24700059690` still spent about `20m57s` in `Build Codex for Termux`, while the repo-local musl CI patterns already show APT caching and alternate runner classes as the safer remaining levers.

- Observation: The release-cache-key hygiene change is confirmed on the real arm shipping path: after removing the workflow file from the cache fingerprint, subsequent workflow-only edits restored the prior release caches and kept the compile step near the old warm-cache number.
  Evidence: arm run `24702957227` restored host and target release caches from `24702317240` and finished `Build Codex for Termux` in about `13m50s`; arm run `24706188602` on the next workflow-only edit remained green at about `14m07s`.

- Observation: Hosted `ubuntu-24.04` x64 is not a useful cold-build accelerator for this aarch64-musl workflow in its current tooling model.
  Evidence: x64 runs `24702518505`, `24702960510`, and `24706196165` failed in sequence on three different host/target separation problems, and the last one still spent about `27m19s` in `Build Codex for Termux` before failing at final link because `/usr/bin/musl-gcc` on x64 cannot link the aarch64 musl CRT objects.


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

- Decision: After the first failed `sccache` run, keep the `sccache` experiment alive for one narrower fix by moving the musl UBSan preload into the build environment and restarting the `sccache` server at build time.
  Rationale: the failure was specific to wrapper composition, while the failed run still saved a reusable `.sccache` payload. One narrow follow-up rerun can prove whether the cache actually buys cold-run speed; if it still fails or yields no meaningful hits, move on to selective `target/` reuse.
  Date/Author: 2026-04-17 / Codex

- Decision: Abandon `sccache` for this musl Termux artifact workflow and switch to selective release-target caching with the repo’s known-good direct rustc UBSan wrapper.
  Rationale: the second rerun kept the same proc-macro UBSan failure even with strong Rust cache hits, and the upstream repo already disables `sccache` on musl before applying the wrapper. Selective `target/` reuse stays inside the workflow-only safe zone without depending on the `sccache` daemon boundary.
  Date/Author: 2026-04-17 / Codex

- Decision: Keep the selective release-target cache experiment, but widen the target cache to include `target/${TARGET}/release/gn_out/obj` before judging the approach.
  Rationale: the first rerun isolated a concrete missing native-output directory rather than a general fingerprint or correctness problem. Adding the `rusty_v8` archive path is a narrow workflow-only fix that preserves the restored green path from run `24544435578`.
  Date/Author: 2026-04-17 / Codex

- Decision: Keep musl `sccache` off, preserve the Android runtime/auth bridge untouched, and spend the next workflow-only iteration on APT archive reuse, release-cache key hygiene, and a controlled x64 runner benchmark.
  Rationale: all three validation threads agreed the helper is no longer the dominant cost, the repo-local evidence still rejects musl `sccache`, and the safest remaining cold-build upside is runner-class experimentation plus avoiding unnecessary warm-cache invalidation when the workflow file changes.
  Date/Author: 2026-04-21 / Codex

- Decision: Keep the real shipping workflow pinned to `ubuntu-24.04-arm` and treat hosted x64 as closed for now.
  Rationale: the arm path is now measurably faster and green, while hosted x64 proved slower and exposed a fundamental missing cross-linker/toolchain issue on the GitHub-hosted image. Leaving an optional broken runner path in the workflow is not worth the repo hygiene cost.
  Date/Author: 2026-04-21 / Codex

- Decision: Do not keep the zig-linker x64 benchmark path in head.
  Rationale: the follow-up benchmark never reached Cargo, exposed two more `libcap`-bootstrap incompatibilities on hosted x64, and still lacked any evidence that it would beat the current arm shipping path on cold builds. Any future x64 attempt needs a different toolchain image or deeper build-surface redesign, not another small workflow tweak.
  Date/Author: 2026-04-21 / Codex


## Outcomes & Retrospective

The deeper compile bottleneck did not move much with dependency/tool bootstrap caching alone: fresh remote builds still land around 20 minutes and still spend almost all of that time in the actual Rust build step. The meaningful win came from not rebuilding when the runtime payload is already known-good. Exact-SHA artifact reuse cut repeat installs to about 20.654 seconds, and runtime-equivalent ancestor reuse cut tooling-only tip installs to about 22.151 seconds. That met the first-phase goal without touching the Termux runtime bridge or Android ChatGPT-login behavior.

The second phase narrowed the viable path. `sccache` clearly accelerated repeated Rust crate compilation on the fork, but it still broke the musl proc-macro load path twice, which makes it unacceptable for this job. The next candidate replaced `sccache` with selective caching of host and target release dependency outputs while restoring the direct `rustc-ubsan-wrapper` pattern that the repo already uses for musl CI.

That candidate cleared the correctness bar on its cold run, then cleared the warm-rerun bar once `target/${TARGET}/release/gn_out/obj` was added. With that path present, warm rerun `24546776031` cut `Build Codex for Termux` to about `13m49s` on the same SHA. The later cache-key hygiene change then held that gain across workflow-only edits on the real arm shipping path: runs `24702957227` and `24706188602` stayed green at about `13m50s` and `14m07s`.

The hosted x64 branch of the experiment was useful only as a negative result. It surfaced three distinct host/target separation problems and still ended slower than arm before failing at final link. The conclusion is straightforward: keep the supported shipping path on `ubuntu-24.04-arm`, keep the release-cache-key change and APT-cache scaffolding, and do not spend more workflow complexity on hosted x64 until there is a proper aarch64 musl cross-linker/toolchain story for that runner.

The later zig-linker spike reinforced the same conclusion. It was the smallest reasonable attempt to salvage hosted x64 without touching the Android shipping path, but it failed twice in `libcap` bootstrap before Cargo could even start. That is no longer a workflow-hygiene problem. Repo head should stay on the arm shipping path, and any future x64 work should start from a different builder image or a purpose-built toolchain plan.


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
- Current helper polling cadence: 10 second loops in `wait_for_remote_run()` and `wait_for_remote_run_since()`.


## Interfaces and Dependencies

- GitHub Actions workflow dispatch/download through `gh`
- Termux install helpers in `scripts/termux/termux-mobile-lib.sh`
- `actions/checkout`, `dtolnay/rust-toolchain`, `mlugg/setup-zig`, and the musl build tooling script
- `patch_audit.tsv` classifications for any new fork-only optimization commits
