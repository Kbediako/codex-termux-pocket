# Termux Codex Upstream Log

This log records lightweight retrospective notes for Codex alpha activity that
matters to the Termux fork. It also notes upstream `origin/main` activity so
daily Termux Pocket backfills can distinguish "no change" days from active
upstream days. Tag dates are read from the upstream git tag metadata after
refreshing `origin`.

## 2026-06-13

- Upstream `origin/main` changed: 9 commits are recorded for this date.
- Notable areas: request-scoped turn state over WebSocket, exec-server cwd
  `PathUri` handling, plugin MCP dedupe, bundled SQLite WAL reset pinning, and
  Windows ARM64 packaging/buildifier maintenance.
- Upstream Codex alpha tags created: `rust-v0.140.0-alpha.18` and
  `rust-v0.140.0-alpha.19`.
- No Termux-specific update action is recorded here for this date.

## 2026-06-14

- Upstream `origin/main` changed: 4 commits are recorded for this date.
- Notable areas: app-server parent-thread filtering, exec-server remote cwd and
  shell handling, native path URI rendering, and the Wine/PowerShell Bazel test
  harness.
- No upstream Codex alpha tags were created on this date.
- No Termux-specific update action is recorded here for this date.

## 2026-06-15

- Upstream `origin/main` changed: 59 commits are recorded for this date.
- Notable areas: plugin/app capability filtering, exec-server Noise relay and
  remote transport defaults, Windows sandbox/session work, rate-limit reset
  usage surfaces, realtime controls, and multi-agent prompt updates.
- Upstream Codex alpha tags created: `rust-v0.140.0-alpha.20`,
  `rust-v0.140.0-alpha.21`, `rust-v0.140.0-alpha.22`,
  `rust-v0.141.0-alpha.1`, `rust-v0.141.0-alpha.2`, and
  `rust-v0.141.0-alpha.3`.
- No Termux-specific update action is recorded here for this date.

## 2026-06-19

- Upstream `origin/main` changed: 15 commits are recorded for this date.
- Notable areas: thread-level multi-agent mode, orchestrator skills and MCP
  config toggles, indexed web search mode, cached/live web access wording,
  remote exec command handling, environment connection timeouts, and skill
  persistence/latency tracing.
- Upstream Codex alpha tags created: `rust-v0.142.0-alpha.4`,
  `rust-v0.142.0-alpha.5`, `rust-v0.142.0-alpha.6`, and
  `rust-v0.142.0-alpha.7`.
- No Termux-specific update action is recorded here for this date.

## 2026-06-20

- Upstream `origin/main` changed: 4 commits are recorded for this date.
- Notable areas: token budget context, configurable compaction reminders,
  MCP-history thread hint prototyping, and context window lineage IDs.
- Upstream Codex alpha tags created: `rust-v0.142.0-alpha.8` and
  `rust-v0.142.0-alpha.9`.
- No Termux-specific update action is recorded here for this date.

## 2026-06-21

- Upstream `origin/main` changed: 11 commits are recorded for this date.
- Notable areas: code-mode runtime ownership, authoritative session shutdown,
  cell terminal state linearization, plan-mode prompt updates, sandbox intent
  for remote exec servers, skill metadata stats, and scalar exec-server tests.
- Upstream Codex alpha tag created: `rust-v0.142.0-alpha.10`.
- No Termux-specific update action is recorded here for this date.

## 2026-06-22

- Upstream `origin/main` changed: 46 commits are recorded for this date.
- Notable areas: remote plugin catalog and sharing flows, permission profile
  availability, PAC/system proxy plumbing, guardian session startup,
  usage-limit reset handling, rollout budget reminder thresholds, MCP tool
  search, environment context/model world state migration, and remote sandbox
  intent/denial reporting.
- Upstream Codex release tag created: `rust-v0.142.0`.
- Upstream Codex alpha tags created: `rust-v0.142.0-alpha.11`,
  `rust-v0.142.0-alpha.12`, `rust-v0.143.0-alpha.2`,
  `rust-v0.143.0-alpha.3`, and `rust-v0.143.0-alpha.4`.
- No Termux-specific update action is recorded here for this date.

## 2026-06-23

- Upstream `origin/main` changed: 72 commits are recorded for this date.
- Notable areas: Codex Apps client/auth/cache handling, multi-agent v2 tool
  namespacing, path URI cleanup, selected plugin roots, managed network sandbox
  context, MCP manager refresh and error metrics, rollout persistence/session
  budget reporting, code-mode host handshake work, thread item listing, image
  generation auth, and token budget compaction context.
- Upstream Codex alpha tags created: `rust-v0.143.0-alpha.1`,
  `rust-v0.143.0-alpha.5`, `rust-v0.143.0-alpha.6`,
  `rust-v0.143.0-alpha.7`, `rust-v0.143.0-alpha.8`,
  `rust-v0.143.0-alpha.9`, `rust-v0.143.0-alpha.10`,
  `rust-v0.143.0-alpha.11`, `rust-v0.143.0-alpha.12`,
  `rust-v0.143.0-alpha.13`, and `rust-v0.143.0-alpha.14`.
- No Termux-specific update action is recorded here for this date.

## 2026-06-24

- Upstream `origin/main` changed: 35 commits are recorded for this date.
- Notable areas: executor plugin connector declarations, app metadata/icon
  wiring, curated plugin sync isolation, plugin install tracking, bounded
  filesystem walk RPCs, environment skill discovery, agent graph/message
  persistence, descendant thread listing, local credential broker work, Windows
  ConPTY/sandbox credential retries, path URI normalization, and CI worktree
  dirtiness checks.
- Upstream Codex release tag created: `rust-v0.142.1`.
- Upstream Codex alpha tags created: `rust-v0.143.0-alpha.15`,
  `rust-v0.143.0-alpha.16`, and `rust-v0.143.0-alpha.17`.
- No Termux-specific update action is recorded here for this date.

## 2026-06-26

- Upstream `origin/main` changed: 32 commits are recorded for this date.
- Notable areas: process-owned code mode host wiring, selected capability
  availability and resume tests, managed new-thread model settings, thread
  `history_mode`, optional `turn_id` on thread fork, delegation authorization
  from AGENTS.md and skills, npm marketplace plugin sources, MCP authentication
  startup errors, rollout turn protocol items, exec-server process events, and
  JSON shutdown logs.
- Upstream Codex release tag created: `rust-v0.142.3`.
- Upstream Codex alpha tag created: `rust-v0.143.0-alpha.26`.
- No Termux-specific update action is recorded here for this date.

## 2026-06-27

- Upstream `origin/main` changed: 5 commits are recorded for this date.
- Notable areas: custom tool call namespace preservation, synthesized call
  output ID stability, environment info RPC, marketplace source policy runtime
  enforcement, and a longer app-server `currentTime/read` timeout.
- Upstream Codex alpha tags created: `rust-v0.143.0-alpha.27`,
  `rust-v0.143.0-alpha.28`, and `rust-v0.143.0-alpha.29`.
- No Termux-specific update action is recorded here for this date.

## 2026-06-28

- Upstream `origin/main` changed: 2 commits are recorded for this date.
- Notable areas: enabling remote plugins by default and clearing completed
  safety-buffering prompts in the TUI.
- No upstream Codex alpha or release tags were created on this date.
- No Termux-specific update action is recorded here for this date.

## 2026-06-29

- Upstream `origin/main` changed so far: 1 commit is recorded for this date as
  of the 2026-06-29 UTC refresh.
- Notable area: skills usage instructions now use model metadata.
- No upstream Codex alpha or release tags were created on this date as of this
  refresh.
- No Termux-specific update action is recorded here for this date.
