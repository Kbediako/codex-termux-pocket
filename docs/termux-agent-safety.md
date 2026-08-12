# Termux Agent Safety

These rules apply when a Codex checkout is maintained directly on native
Android/Termux. They override conflicting repository instructions that assume a
supported GNU/Linux, macOS, or Windows development host.

## Native execution boundary

- Do not run phone-side Rust compilation or test commands for the Codex
  checkout. This includes `cargo build`, `cargo check`, `cargo test`,
  `cargo install`, `cargo binstall`, `rustc`, `maturin`, `just fmt`, `just fix`,
  and `just test`. Do not install `cargo-nextest` on the phone.
- Treat Bazel-backed lints, lock/schema generators, benchmarks, and similar
  build-capable commands as supported-host or hosted-CI-only unless read-only
  inspection proves the exact invocation cannot compile or execute native code.
- Do not directly execute `codex-linux-sandbox`, bundled `bwrap`, Landlock or
  seccomp probes, or restricted-command sandbox smoke tests on this device.
  Android is not Linux for Rust `target_os`, and previous work near this
  boundary coincided with device reboots. Treat this as a safety restriction,
  not as proof of a particular kernel root cause.

## Allowed local checks

Non-compiling inspection is allowed when useful, including
`cargo metadata --locked`, source inspection, YAML parsing, `bash -n`,
`git diff --check`, and targeted Prettier checks.

The native Termux `uv` package is installed and may be used for lightweight
compatible tasks. Do not use it to run this repository's Ruff formatter on
Android: `uv run` attempts to compile Rust-backed Ruff/Maturin dependencies
from source here. The full repository formatter also requires DotSlash, which
is not available as a supported Termux package.

## Hosted validation and releases

- Validate Codex Rust and Linux-sandbox changes on hosted Linux CI. The fork's
  `.github/workflows/termux-linux-sandbox.yml` runs the locked scoped suite on
  native hosted x64 and ARM64 Ubuntu runners.
- Before publishing every mobile alpha, run that workflow against the
  candidate's full commit SHA. An alpha-number change does not require editing
  the workflow. Update it only when its action/toolchain/nextest pins, runner
  labels, or required Linux packages change.
- A workflow dispatch, commit, push, release, or other remote mutation still
  requires the user's authorization. Preserve unrelated local edits.
