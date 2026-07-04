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

## Android / Termux

This fork keeps the mobile update path artifact-first:

- `codex-update-alpha` is the default updater.
- `--mode auto` prefers the upstream ARM64 musl alpha artifact, then a fork-built
  remote artifact, and only allows a local source retry when
  `CODEX_TERMUX_ALLOW_SOURCE_FALLBACK=1` is set.
- The installed `codex` command is a Termux launcher wrapper that bridges DNS
  and CA bundle paths through `proot` and sets `termux-open-url` for
  browser-based login flows.
- `codex self-update` still syncs the checkout, but it refuses the broken local
  Termux Cargo rebuild by default.

Useful commands:

```shell
codex-update-alpha
codex-update-alpha --check
codex-update-alpha --mode remote-artifact --remote-ref main
codex-cargo-check
```

Details, recovery rules, and the experimental source fallback are documented in
[Termux Mobile Update Flow](./docs/termux-mobile-update.md).

## Docs

- [**Contributing**](./docs/contributing.md)

This repository is licensed under the [Apache-2.0 License](LICENSE).
