# Private voice helper foundation

`codex-voice-host` establishes the inherited-pipe lifecycle for the proposed
bundled voice process and owns WebRTC negotiation. It does not open devices or
enable voice in the TUI. The existing CLI is unchanged.

Frames are a big-endian u32 length followed by at most 128 KiB of JSON. SDP is
limited to 64 KiB and redacted in diagnostics. The
parent sends `hello` with protocol `1` and the helper's exact `buildCommit` before
receiving `ready`. It then sends `close` and receives `closed` before process exit.
After `ready`, the parent may send `initializeRuntime` once. `runtimeReady` means
the physical package's GStreamer library and seven explicit plugins initialized;
it does not mean an audio session started. Missing or invalid runtime files cause
the helper to exit without a readiness response or raw native diagnostics. The
client terminates the helper if initialization fails or exceeds its deadline.
Unknown fields, incompatible builds, invalid order and oversized frames fail
closed without echoing input. EOF exits even when the main worker cannot progress.

After `ready`, `startTransport` gathers an `offer`; `applyAnswer` returns
`transportReady` only when the ordered `oai-events` channel opens. This can run
without native audio initialization and does not establish audio readiness.
Negotiation has a deadline; `close` tears down the peer before acknowledging exit.
UDP and TCP peer tests use real sockets, without a backend or audio devices.

Bazel stamps the binary with `STABLE_GIT_COMMIT`. Cargo builders must provide the
same variable; an unstamped source build reports `dev` via `--build-commit` and is
not a distributable build identity. The client/control crate has no native audio
dependencies. `VoiceHost` resolves only the physical package's
`codex-resources/voice/bin/codex-voice-host[.exe]`, filters the child environment,
and owns process cleanup through `codex-utils-pty`. Its runtime must remain alive
to reap a dropped helper; explicit `close` waits for process exit.

For private feasibility artifacts, `third_party/voice/assemble_package.py` copies
an existing validated package into a fresh output and adds the helper. Supply
`--package`, `--helper`, `--voice-target`, `--build-commit`, and `--output`.
Linux MUSL apps require same-architecture GNU helpers; other targets must match.
The package version must end in `+<build-commit>`. The manifest records declared
build provenance and file hashes, not authentication or binary architecture proof.
Add `--runtime <prepared-runtime>` to include the platform preparer's selected
libraries and `runtime.json` beside the helper. The assembler checks the target,
pinned source manifest, plugin list, relative paths and file hashes, then checks
the copied hashes again. It preserves `lib/` and `plugins/` on macOS, `lib/` and
`lib/gstreamer-1.0/` on Linux, and the shared `bin/` on Windows. Unlisted files are
not copied. The package manifest records every included runtime file and the
unchanged runtime receipt.
Omitting `--runtime` retains helper-only assembly.

This accepts a development runtime receipt, not an authenticated release. It
does not repeat native loader inspection or establish trust in the build inputs.
The helper opens only physical packaged paths. The parent fixes GStreamer search
paths to empty, disables registry updates/forking, and points its registry to the
OS null device. Windows loads use only the DLL's directory and System32. Native
libraries remain loaded until helper exit, even after partial initialization,
because GStreamer registers process-global callbacks. The small private C ABI
bootstrap does not expose native pointers to the parent or link native libraries
into ordinary Codex. The existing `libloading` dependency supplies OS loading.
Media/privacy controls, a full media binding layer and actual audio proof remain
integration stages; helper-only packages continue to support lifecycle calls.

The ignored `packaged_runtime` integration test uses real libraries prepared for
the host platform. From `codex-rs`, run
`CODEX_TEST_VOICE_RUNTIME=/absolute/prepared/runtime just test -p codex-voice-host --test packaged_runtime --run-ignored all`.
It copies and relocates the runtime with the real helper, checks client
initialization and close, and rejects duplicate initialization. This requires
native inputs separately; ordinary CI does not run this ignored test. It tests
helper loading, not microphone, speaker, backend, or release behavior.
