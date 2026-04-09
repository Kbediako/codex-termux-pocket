<p align="center"><code>npm i -g @openai/codex</code><br />or <code>brew install --cask codex</code></p>
<p align="center"><strong>Codex CLI</strong> is a coding agent from OpenAI that runs locally on your computer.</p>
<p align="center">
  <img src="https://github.com/openai/codex/blob/main/.github/codex-cli-splash.png" alt="Codex CLI splash" width="80%" />
</p>

If you want Codex in your code editor (VS Code, Cursor, Windsurf), <a href="https://developers.openai.com/codex/ide">install in your IDE</a>.<br />
If you want the desktop app experience, run <code>codex app</code> or visit <a href="https://chatgpt.com/codex?app-landing-page=true">the Codex App page</a>.<br />
If you are looking for the <em>cloud-based agent</em> from OpenAI, <strong>Codex Web</strong>, go to <a href="https://chatgpt.com/codex">chatgpt.com/codex</a>.

---

## Android / Termux (this fork)

This fork is tuned for running Codex on Android with Termux:

- Keeps `codex self-update` (alias `update-self`) for local checkout syncs, but local Cargo rebuilds are disabled by default until the Termux V8 link issue is resolved.
- Embeds the build version so `codex --version` reflects the git describe.
- `codex-update-alpha --mode auto` now prefers verified ARM64 artifacts and fork remote artifacts before any experimental local Cargo rebuild.
- `self-update` can still retry the low-memory Termux build profile with `CODEX_TERMUX_ALLOW_SOURCE_FALLBACK=1`, but the default path is artifact-first.

Recommended Termux flow for this fork:

```shell
git clone https://github.com/Kbediako/codex-termux-pocket.git ~/codex
mkdir -p ~/bin
cp ~/codex/scripts/termux/codex-update-alpha ~/bin/
chmod 700 ~/bin/codex-update-alpha
codex-update-alpha
```

`codex-update-alpha` is the preferred updater for this rebased fork. It checks the newest upstream alpha tag, rebases the local Termux patch stack onto it, pushes `main` to your configured fork remote when available, then installs using the quickest safe path:

- upstream ARM64 musl alpha artifact when the local patch audit allows it
- fork-built remote artifact from GitHub Actions when local runtime patches still matter
- experimental low-memory local source build only when `CODEX_TERMUX_ALLOW_SOURCE_FALLBACK=1` is set

`codex self-update` still syncs the local checkout, but on Termux it now refuses the local Cargo rebuild by default because the Android-targeted V8 link remains broken. Set `CODEX_TERMUX_ALLOW_SOURCE_FALLBACK=1` only if you want to retry that build experimentally.

Alpha helper commands:

```shell
# update to newest alpha tag (skips rebuild if already current)
codex-update-alpha

# check only (tag query only; no full branch fetch)
codex-update-alpha --check

# retry the local source build experimentally
CODEX_TERMUX_ALLOW_SOURCE_FALLBACK=1 codex-update-alpha --mode source --force

# force the upstream artifact path when the patch audit allows it
codex-update-alpha --mode artifact --force

# build and install a fork artifact for a branch or commit
codex-update-alpha --mode remote-artifact --remote-ref main

# force reinstall using whichever mode auto selects
codex-update-alpha --force
```

By default, both update paths expect the source checkout at `~/codex`. You can set `CODEX_SRC_DIR` to point at a different source tree.

See [Termux Mobile Update Flow](./docs/termux-mobile-update.md) for patch-audit behavior, remote artifact prerequisites, and recovery rules.

## Quickstart

### Installing and running Codex CLI

Install globally with your preferred package manager:

```shell
# Install using npm
npm install -g @openai/codex
```

```shell
# Install using Homebrew
brew install --cask codex
```

Then simply run `codex` to get started.

<details>
<summary>You can also go to the <a href="https://github.com/openai/codex/releases/latest">latest GitHub Release</a> and download the appropriate binary for your platform.</summary>

Each GitHub Release contains many executables, but in practice, you likely want one of these:

- macOS
  - Apple Silicon/arm64: `codex-aarch64-apple-darwin.tar.gz`
  - x86_64 (older Mac hardware): `codex-x86_64-apple-darwin.tar.gz`
- Linux
  - x86_64: `codex-x86_64-unknown-linux-musl.tar.gz`
  - arm64: `codex-aarch64-unknown-linux-musl.tar.gz`

Each archive contains a single entry with the platform baked into the name (e.g., `codex-x86_64-unknown-linux-musl`), so you likely want to rename it to `codex` after extracting it.

</details>

### Using Codex with your ChatGPT plan

Run `codex` and select **Sign in with ChatGPT**. We recommend signing into your ChatGPT account to use Codex as part of your Plus, Pro, Business, Edu, or Enterprise plan. [Learn more about what's included in your ChatGPT plan](https://help.openai.com/en/articles/11369540-codex-in-chatgpt).

You can also use Codex with an API key, but this requires [additional setup](https://developers.openai.com/codex/auth#sign-in-with-an-api-key).

## Docs

- [**Codex Documentation**](https://developers.openai.com/codex)
- [**Contributing**](./docs/contributing.md)
- [**Installing & building**](./docs/install.md)
- [**Open source fund**](./docs/open-source-fund.md)

This repository is licensed under the [Apache-2.0 License](LICENSE).
