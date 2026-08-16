#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/termux-android-emulator.yml"
CHECK = ROOT / ".github/scripts/termux-android-emulator-check.sh"
SELF_WORKFLOW = ROOT / ".github/workflows/termux-fix-android-gate.yml"
SELF = Path(__file__).resolve()


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one exact match, found {count}")
    return text.replace(old, new, 1)


def main() -> int:
    text = WORKFLOW.read_text(encoding="utf-8")
    text = replace_once(
        text,
        '''          cargo build --locked --target "$TARGET" --release --bin bwrap
          cargo build --locked --target "$TARGET" --release \\
            --bin codex \\
            --bin codex-code-mode-host \\
            --bin codex-responses-api-proxy
''',
        '''          cargo build --locked --target "$TARGET" --release \\
            --bin codex \\
            --bin codex-code-mode-host \\
            --bin codex-responses-api-proxy
''',
        "bundled-bwrap build block",
    )
    text = replace_once(
        text,
        '''          cp "target/${TARGET}/release/bwrap" "${runtime_root}/codex-resources/bwrap"
          strip --strip-debug --strip-unneeded "${runtime_root}/codex-resources/bwrap"
          chmod 0755 "${runtime_root}/codex-resources/bwrap"
''',
        '''          cat >"${RUNNER_TEMP}/bwrap-termux-ci.c" <<'EOF_BWRAP'
          #include <stdio.h>
          #include <string.h>

          int main(int argc, char **argv) {
            if (argc == 2 && strcmp(argv[1], "--version") == 0) {
              puts("bubblewrap 0.0.0-termux-android-ci");
              return 0;
            }
            fputs("The Android emulator surrogate intentionally disables bubblewrap; use the Landlock fallback.\\n", stderr);
            return 125;
          }
          EOF_BWRAP
          "${CC:-cc}" -static -Os \\
            "${RUNNER_TEMP}/bwrap-termux-ci.c" \\
            -o "${runtime_root}/codex-resources/bwrap"
          strip --strip-debug --strip-unneeded "${runtime_root}/codex-resources/bwrap"
          chmod 0755 "${runtime_root}/codex-resources/bwrap"
''',
        "bundled-bwrap stage block",
    )
    WORKFLOW.write_text(text, encoding="utf-8")

    check_text = CHECK.read_text(encoding="utf-8")
    check_text = replace_once(
        check_text,
        "smoke-test-artifact --installed\n",
        "CODEX_TERMUX_DISABLE_PROOT=1 smoke-test-artifact --installed\n",
        "installed smoke invocation",
    )
    CHECK.write_text(check_text, encoding="utf-8")

    SELF_WORKFLOW.unlink(missing_ok=True)
    SELF.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
