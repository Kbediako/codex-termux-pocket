# Termux Install, Update, and Recovery

The supported phone workflow installs a verified runtime artifact. It never
rebases the checkout, creates commits, asks for Git author identity, or attempts
the known-broken Android/V8 source build.

## What the installer configures

`install-codex-termux` is safe to rerun. It installs required Termux packages,
including Node.js for bundled plugin MCP servers, clones or fast-forwards
`~/codex`, copies the helpers to `$PREFIX/bin`, installs the maintained runtime,
and runs an end-to-end smoke test.

Its Git remotes have deliberately separate roles:

- `origin` is `Kbediako/codex-termux-pocket` and is the only default push remote.
- `upstream` is `https://github.com/openai/codex.git`, supplies OpenAI tags, and
  has a disabled push URL.

An existing checkout is updated only when it is clean, on `main`, and can
fast-forward. Anything dirty, divergent, or unrelated is left untouched with
an actionable error.

## Artifact trust and layout

The maintained release provides three files:

- `codex-termux-aarch64-unknown-linux-musl.tar.gz`
- `metadata.env`
- `SHA256SUMS`

The committed `scripts/termux/release-manifest.env` pins its release tag, exact
source commit, reported Codex version, and archive SHA-256. The installer checks
both checksum manifests, rejects a different commit/version/target, rejects
unsafe archive paths, and verifies every executable before changing the active
runtime.

The runtime uses the canonical package layout under
`$PREFIX/libexec/codex-termux/releases/<commit>/`:

```text
bin/codex
bin/codex-code-mode-host
bin/codex-responses-api-proxy
codex-resources/bwrap
codex-package.json
metadata.env
```

`current` is an atomically replaced symlink. `$PREFIX/bin/codex` is an
atomically replaced launcher, so a failed download or validation cannot leave a
half-installed runtime.

## Commands

Install or update to the maintained release:

```shell
codex-update-alpha update
```

Before reading the maintained release pointer, the updater fetches `origin/main`
and fast-forwards the dedicated clean checkout. It refuses dirty, non-`main`,
or divergent state instead of stashing, resetting, or rebasing it.

Compare the installed runtime with the maintained release and separately show
the latest alpha tag found on OpenAI `upstream`:

```shell
codex-update-alpha check
```

`check` exits 0 when current and 10 when an install/update is needed.

Run the complete installed smoke test:

```shell
smoke-test-artifact --installed
```

It validates the launcher, exact metadata/version, all runtime sidecars,
bundled bubblewrap, DNS and CA paths, Android browser handoff, executable
permissions, a DNS/TLS request to the OpenAI API endpoint, and a token-producing
command through the Codex command runner. It also proves that the runner finds
the verified bundled `bwrap` instead of emitting the missing-bubblewrap warning.

## Queued Actions runs

Public release downloads do not require GitHub authentication. Direct GitHub
Actions artifact downloads do, because the Actions artifact API requires it;
run `gh auth login` only when using this recovery path.

The default local wait is two hours (`7200` seconds), which leaves headroom for
ARM runner queues. Override it with `--timeout` or `CODEX_TERMUX_TIMEOUT`.
Status messages distinguish queued, running, successful, failed, and locally
timed-out states and always include the run ID and URL.

If a local wait times out, the workflow is not cancelled. Resume it exactly as
printed by the updater:

```shell
codex-update-alpha wait --run-id RUN_ID --expected-sha COMMIT_SHA
```

Install from an already-successful run without dispatching anything:

```shell
codex-update-alpha install-run --run-id RUN_ID --expected-sha COMMIT_SHA
```

The updater reuses an exact queued, running, or successful match. It does not
substitute an ancestor artifact and does not automatically duplicate a failed
run. `--dispatch` is an explicit maintainer/advanced operation and is never
needed for a published maintained release.

## Bubblewrap on Termux

The complete runtime ships the same-revision `bwrap` under
`codex-resources/bwrap`. The launcher prepends that verified resource directory
to `PATH`, so Codex finds its bundled copy without printing the generic
“install bubblewrap with your OS package manager” warning. There is no need to
seek an unsupported Termux package merely to suppress that warning.

Stock Android kernels do not generally expose the user/mount namespaces that
Linux bubblewrap needs. Earlier Termux runtimes attempted an in-process
Landlock filesystem plus seccomp network fallback. Repeated full-device
reboots were observed at that restricted-command boundary, while Android
denied unprivileged Termux access to the boot reason, kernel log, and pstore
records needed to distinguish a Landlock, seccomp, firmware, thermal, or
unrelated system failure.

The maintained runtime therefore fails closed: on Termux, an invocation that
would enter the Linux sandbox helper exits before bubblewrap, Landlock,
seccomp, or the requested payload. The full smoke test checks that refusal and
proves its marker payload was not executed. Do not weaken the configured
permission profile merely to suppress this refusal. The bundled `bwrap`
remains version-checked as part of the complete same-revision runtime, but
stock Android cannot use it as a security boundary. `proot` is used only for
DNS/CA path bridging and is not treated as a security sandbox.

The launcher also binds Termux `resolv.conf` and CA bundle to conventional Linux
paths with `proot`, exports the Termux CA variables, and uses
`termux-open-url` for `codex login` browser handoff. Set
`CODEX_TERMUX_DISABLE_PROOT=1` only for targeted debugging.

## Recovery rules

- Rerun `install-codex-termux`; all normal operations are idempotent.
- A checksum, commit, version, target, sidecar, or executable failure is fatal.
  Do not bypass it or install files manually.
- A dirty/divergent checkout is never stashed or reset. Use a separate
  `CODEX_SRC_DIR` if the checkout contains your work.
- No phone fallback runs Cargo. Maintainer source maintenance is described in
  [Termux Maintainer Guide](./termux-maintainer.md).
