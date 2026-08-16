#!/usr/bin/env bash
set -euo pipefail

source_script="${GITHUB_WORKSPACE}/.github/scripts/termux-android-emulator-check.sh"
patched_script="${RUNNER_TEMP}/termux-android-emulator-check-noninteractive.sh"

python3 - "$source_script" "$patched_script" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
text = source.read_text(encoding="utf-8")
old = """pkg update -y
pkg install -y bash git curl ca-certificates coreutils findutils tar gzip nodejs proot termux-tools ripgrep
"""
new = """export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=a
apt-get update
apt-get -y \\
  -o Dpkg::Options::=--force-confdef \\
  -o Dpkg::Options::=--force-confold \\
  install bash git curl ca-certificates coreutils findutils tar gzip nodejs proot termux-tools ripgrep
"""
count = text.count(old)
if count != 1:
    raise SystemExit(
        f"expected exactly one Termux package bootstrap block, found {count}"
    )
destination.write_text(text.replace(old, new, 1), encoding="utf-8")
PY

chmod 0755 "$patched_script"
exec "$patched_script"
