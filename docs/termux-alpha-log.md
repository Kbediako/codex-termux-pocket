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
