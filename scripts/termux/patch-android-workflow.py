#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/termux-android-emulator.yml"
SELF_WORKFLOW = ROOT / ".github/workflows/termux-patch-android-workflow.yml"
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
        "  cancel-in-progress: false\n",
        "  cancel-in-progress: true\n",
        "Android workflow concurrency",
    )

    anchor = '''      - name: Save Cargo dependency cache
        if: always() && !cancelled()
        continue-on-error: true
        uses: actions/cache/save@668228422ae6a00e4ad889ee87cd7109ec5666a7 # v5
        with:
          path: |
            ${{ github.workspace }}/.cargo-home-emulator/registry/index/
            ${{ github.workspace }}/.cargo-home-emulator/registry/cache/
            ${{ github.workspace }}/.cargo-home-emulator/git/db/
          key: termux-emulator-cargo-${{ runner.os }}-${{ env.TARGET }}-${{ hashFiles('codex-rs/Cargo.lock', 'codex-rs/rust-toolchain.toml') }}
'''
    addition = anchor + '''
      - name: Save compiled target cache
        if: always() && !cancelled()
        continue-on-error: true
        uses: actions/cache/save@668228422ae6a00e4ad889ee87cd7109ec5666a7 # v5
        with:
          path: |
            codex-rs/target/.rustc_info.json
            codex-rs/target/release/.fingerprint/
            codex-rs/target/release/build/
            codex-rs/target/release/deps/
            codex-rs/target/x86_64-unknown-linux-musl/.rustc_info.json
            codex-rs/target/x86_64-unknown-linux-musl/release/.fingerprint/
            codex-rs/target/x86_64-unknown-linux-musl/release/build/
            codex-rs/target/x86_64-unknown-linux-musl/release/deps/
            codex-rs/target/x86_64-unknown-linux-musl/release/gn_out/obj/
          key: termux-emulator-target-${{ runner.os }}-${{ env.TARGET }}-${{ hashFiles('codex-rs/Cargo.lock', 'codex-rs/rust-toolchain.toml') }}-${{ needs.prepare.outputs.source_sha }}
'''
    text = replace_once(text, anchor, addition, "Cargo cache save block")
    WORKFLOW.write_text(text, encoding="utf-8")

    SELF_WORKFLOW.unlink(missing_ok=True)
    SELF.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
