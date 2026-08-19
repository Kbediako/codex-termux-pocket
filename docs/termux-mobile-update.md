# Termux Install, Update, and Recovery

The supported phone workflow installs a verified runtime artifact. It never
rebases the checkout, creates commits, asks for Git author identity, or attempts
the known-broken Android/V8 source build.

## What the installer configures

`install-codex-termux` is safe to rerun. It installs required Termux packages,
including Node.js for bundled plugin MCP servers, clones or fast-forwards the
managed helper checkout at `~/.local/share/codex-termux-pocket/repo`, copies the
helpers to `$PREFIX/bin`, installs the maintained runtime, and runs an
end-to-end smoke test. Your own `~/codex` working tree is never used. Set
`CODEX_TERMUX_CHECKOUT_DIR` only to choose a different dedicated helper
checkout.

Its Git remotes have deliberately separate roles:

- `origin` is `Kbediako/codex-termux-pocket` and is the only default push remote.
- `upstream` is `https://github.com/openai/codex.git`, supplies OpenAI tags, and
  has a disabled push URL.

The managed checkout is updated only when it is clean, on `main`, and can
fast-forward. Anything dirty, divergent, or unrelated is left untouched with
an actionable error.

## Artifact trust and layout

The maintained release provides five files:

- `codex-termux-aarch64-unknown-linux-musl.tar.gz`
- `metadata.env`
- `SHA256SUMS`
- `codex-termux-sbom.spdx.json`
- `release-manifest.env`

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
and fast-forwards the dedicated managed checkout. It refuses dirty, non-`main`,
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
Linux bubblewrap needs. On Termux, Codex now automatically uses an in-process
Landlock filesystem plus seccomp network fallback instead. Android SELinux
denies opening `/` itself, so the fallback grants read access only through a
fail-closed list of accessible Android system trees and the Termux app tree.
The musl helper opens those rule roots with `O_PATH`: Android permits that
descriptor-only lookup for virtual trees such as `/apex` even when it denies a
normal read-open of the directory. This keeps Android's dynamic-linker paths in
the Landlock allowlist without granting file writes or relying on root access.
This follows the kernel's path-beneath Landlock model and Termux's documented
SELinux-constrained filesystem layout:
[Landlock kernel documentation](https://docs.kernel.org/userspace-api/landlock.html),
[Termux filesystem layout](https://github.com/termux/termux-packages/wiki/Termux-file-system-layout).

Landlock cannot represent nested read-only carve-outs below a writable parent.
When a profile such as `:workspace` requires those carve-outs, the fallback is
made more restrictive—not less—by enforcing read-only filesystem access. A
write is denied and can follow Codex's normal explicit approval path. The full
smoke test proves a restricted `:workspace` command can execute, that an
unapproved write is denied, and that the matching bundled `bwrap` remains
discoverable. `proot` is used only for DNS/CA path bridging and is not treated
as a security sandbox.

The launcher also binds Termux `resolv.conf` and CA bundle to conventional Linux
paths with `proot`, exports the Termux CA variables, and uses
`termux-open-url` for `codex login` browser handoff. Set
`CODEX_TERMUX_DISABLE_PROOT=1` only for targeted debugging.

## Recovery rules

- Rerun `install-codex-termux`; all normal operations are idempotent.
- A checksum, commit, version, target, sidecar, or executable failure is fatal.
  Do not bypass it or install files manually.
- A dirty or divergent managed checkout is never stashed or reset. Set
  `CODEX_TERMUX_CHECKOUT_DIR` only when intentionally choosing a different
  dedicated helper checkout.
- No phone fallback runs Cargo. Maintainer source maintenance is described in
  [Termux Maintainer Guide](./termux-maintainer.md).
