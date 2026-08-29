#!/usr/bin/env bash
set -euo pipefail

# Bootstrap the last proven exact-source alpha transaction from its immutable
# commit, then adapt only the official alpha.12 release identity. Keep the
# bootstrap directory distinct from the adapted transaction's work directory.
base="https://raw.githubusercontent.com/Kbediako/codex-termux-pocket/09c509971074d56dab9f92043b4bcb851a2864f2/.github/scripts/alpha1515-maintenance.sh"
bootstrap="${RUNNER_TEMP:?RUNNER_TEMP is required}/alpha15112-bootstrap"
mkdir -p "$bootstrap"
curl --fail --location --silent --show-error --retry 5 \
  "$base" -o "$bootstrap/original.sh"

python3 - "$bootstrap/original.sh" "$bootstrap/adapted.sh" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
replacements = {
    "rust-v0.151.0-alpha.5": "rust-v0.151.0-alpha.12",
    "e6e0c4fb8c0340800f4066c50e849149e4ecd912": "b676b03adc50cde41bc38426a1c16d44c122f135",
    "0.151.0-alpha.5": "0.151.0-alpha.12",
    "ALPHA1515": "ALPHA15112",
    "alpha1515": "alpha15112",
}
for old, new in replacements.items():
    if old not in source:
        raise SystemExit(f"proven alpha.5 wrapper is missing expected token: {old}")
    source = source.replace(old, new)

for required in (
    "rust-v0.151.0-alpha.12",
    "b676b03adc50cde41bc38426a1c16d44c122f135",
    "0.151.0-alpha.12",
    "alpha15112-maintenance",
):
    if required not in source:
        raise SystemExit(f"adapted wrapper is missing {required}")
Path(sys.argv[2]).write_text(source, encoding="utf-8")
PY

chmod +x "$bootstrap/adapted.sh"
bash -n "$bootstrap/adapted.sh"
exec "$bootstrap/adapted.sh"
