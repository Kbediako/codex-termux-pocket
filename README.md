# Codex Termux Pocket

This fork is focused on running and updating Codex CLI on Android through
Termux. It keeps the mobile install path artifact-first and preserves the
Termux launcher wrapper needed for DNS, CA bundle, and browser auth handoff.

For macOS, Windows, Linux desktop, or other PC installs, use the main
[OpenAI Codex](https://github.com/openai/codex) project.

<p align="center">
  <img
    src=".github/assets/termux-codex-screenshot.jpg"
    alt="Codex CLI running in Termux on Android"
    width="70%"
  />
</p>

## Easy Termux Setup

Use current Termux from F-Droid or the Termux GitHub releases, not the obsolete
Play Store build. On a fresh aarch64 phone, open Termux and paste:

```shell
pkg update -y && pkg install -y curl && curl -fsSL https://raw.githubusercontent.com/Kbediako/codex-termux-pocket/main/scripts/termux/install-codex-termux | bash
```

Then run `codex login` and choose the browser flow. The installer is idempotent,
does not create commits or rebase source, and leaves unrelated/dirty checkouts
untouched.

## Android / Termux

Normal installs consume a maintained, complete aarch64 runtime bundle. The
bundle includes `codex`, `codex-code-mode-host`, the matching response proxy,
and the matching bundled `bwrap`, all from one commit and protected by SHA-256
checksums. The launcher exposes that bundled `bwrap` on `PATH`; do not install
an unsupported Termux package merely to silence the generic desktop warning.
Android namespace limits and the command-runner fallback are documented in
[Termux Mobile Update](./docs/termux-mobile-update.md#bubblewrap-on-termux).
Restricted commands use Landlock plus seccomp on stock Android; no root,
unsupported bubblewrap package, or global sandbox disable is required.

Useful commands:

```shell
codex-update-alpha
codex-update-alpha check
codex-update-alpha wait --run-id RUN_ID --expected-sha COMMIT_SHA
codex-update-alpha install-run --run-id RUN_ID --expected-sha COMMIT_SHA
smoke-test-artifact --installed
```

Update/recovery details are in [Termux Mobile Update](./docs/termux-mobile-update.md).
Rebasing and release publication are maintainer-only and documented in
[Termux Maintainer Guide](./docs/termux-maintainer.md).

## Docs

- [**Contributing**](./docs/contributing.md)

This repository is licensed under the [Apache-2.0 License](LICENSE).
