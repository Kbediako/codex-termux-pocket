#!/usr/bin/env bash
set -euo pipefail

# Bootstrap the last proven alpha.5 transaction from its immutable commit, then
# adapt only the exact alpha.6 release identity. Keep this bootstrap directory
# distinct from the adapted transaction's own alpha1516-maintenance directory;
# otherwise the nested generator would overwrite the script currently running.
base="https://raw.githubusercontent.com/Kbediako/codex-termux-pocket/09c509971074d56dab9f92043b4bcb851a2864f2/.github/scripts/alpha1515-maintenance.sh"
bootstrap="${RUNNER_TEMP:?RUNNER_TEMP is required}/alpha1516-bootstrap"
mkdir -p "$bootstrap"
curl --fail --location --silent --show-error --retry 5 \
  "$base" -o "$bootstrap/original.sh"

python3 - "$bootstrap/original.sh" "$bootstrap/adapted.sh" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
replacements = {
    "rust-v0.151.0-alpha.5": "rust-v0.151.0-alpha.6",
    "e6e0c4fb8c0340800f4066c50e849149e4ecd912": "42cd2e3425834ee77c0b76c121cd43541d69810b",
    "0.151.0-alpha.5": "0.151.0-alpha.6",
    "ALPHA1515": "ALPHA1516",
    "alpha1515": "alpha1516",
}
for old, new in replacements.items():
    if old not in source:
        raise SystemExit(f"proven alpha.5 wrapper is missing expected token: {old}")
    source = source.replace(old, new)

for required in (
    "rust-v0.151.0-alpha.6",
    "42cd2e3425834ee77c0b76c121cd43541d69810b",
    "0.151.0-alpha.6",
    "alpha1516-maintenance",
):
    if required not in source:
        raise SystemExit(f"adapted wrapper is missing {required}")
Path(sys.argv[2]).write_text(source, encoding="utf-8")
PY

chmod +x "$bootstrap/adapted.sh"
bash -n "$bootstrap/adapted.sh"
exec "$bootstrap/adapted.sh"
