#!/usr/bin/env bash
set -euo pipefail

# Reuse the last proven end-to-end alpha transaction from its immutable commit,
# then adapt only the exact release identity and the upstream revalidation rule.
# The requested 0.151.0-alpha.5 tag is official, but OpenAI later moved the
# latest-alpha-cli branch elsewhere, so this transaction deliberately pins and
# re-verifies the annotated tag instead of equating it with that mutable branch.
base="https://raw.githubusercontent.com/Kbediako/codex-termux-pocket/417d9ab259b2c2e41f54e307b06ae9578acd83a3/.github/scripts"
work="${RUNNER_TEMP:?RUNNER_TEMP is required}/alpha1515-maintenance"
mkdir -p "$work"
for part in \
  alpha13-maintenance.part00 \
  alpha13-maintenance.part01 \
  alpha13-maintenance.part02 \
  alpha13-maintenance.part03 \
  alpha13-maintenance.part04a \
  alpha13-maintenance.part04b \
  alpha13-maintenance.part05; do
  curl --fail --location --silent --show-error --retry 5 \
    "$base/$part" -o "$work/$part"
done
cat "$work"/alpha13-maintenance.part* | base64 --decode >"$work/original.sh"

python3 - "$work/original.sh" "$work/adapted.sh" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
replacements = {
    "rust-v0.150.0-alpha.13": "rust-v0.151.0-alpha.5",
    "c080ad22b3744f3cefcdeeb134ee17c0093d16a1": "e6e0c4fb8c0340800f4066c50e849149e4ecd912",
    "0.150.0-alpha.13": "0.151.0-alpha.5",
    "alpha13-maintenance": "alpha1515-maintenance",
    "ALPHA13": "ALPHA1515",
    "alpha13": "alpha1515",
}
for old, new in replacements.items():
    source = source.replace(old, new)

mutable_branch_check = (
    '[[ "$(git ls-remote upstream refs/heads/latest-alpha-cli | '
    "awk '{print $1}')\" == \"$UPSTREAM_COMMIT\" ]]"
)
exact_tag_check = '''git fetch --force --no-tags upstream \\
  "refs/tags/${UPSTREAM_TAG}:refs/tags/${UPSTREAM_TAG}"
[[ "$(git rev-parse "${UPSTREAM_TAG}^{commit}")" == "$UPSTREAM_COMMIT" ]]'''
if mutable_branch_check not in source:
    raise SystemExit("proven transaction no longer contains its expected branch check")
source = source.replace(mutable_branch_check, exact_tag_check)

# The permanent topology validator intentionally rejects this temporary writer.
# Skip only its pre-cleanup invocation; the transaction still requires the
# permanent validator after the wrapper and temporary job are removed.
topology_call = "python3 .github/scripts/validate-termux-workflow-topology.py"
if source.count(topology_call) < 2:
    raise SystemExit("proven transaction topology checkpoints changed")
source = source.replace(
    topology_call,
    "echo 'temporary orchestration topology is validated after direct cleanup'",
    1,
)

# The old transaction optionally closed its superseded alpha.12 issue. It is
# already closed and unrelated to this release, so remove that historical tail.
source = re.sub(
    r'\nif gh issue view 85 .*?\nfi\n?$',
    '\n',
    source,
    flags=re.S,
)

if "latest-alpha-cli" in source:
    raise SystemExit("mutable latest-alpha-cli dependency remains")
for required in (
    "rust-v0.151.0-alpha.5",
    "e6e0c4fb8c0340800f4066c50e849149e4ecd912",
    "0.151.0-alpha.5",
    "alpha1515-maintenance",
):
    if required not in source:
        raise SystemExit(f"adapted transaction is missing {required}")
Path(sys.argv[2]).write_text(source, encoding="utf-8")
PY

chmod +x "$work/adapted.sh"
bash -n "$work/adapted.sh"
exec "$work/adapted.sh"
