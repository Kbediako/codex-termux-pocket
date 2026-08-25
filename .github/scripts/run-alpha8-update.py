#!/usr/bin/env python3
"""Run the bounded, exact-source Codex 0.150.0-alpha.8 updater."""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

SOURCE = Path(".github/scripts/update-alpha-0.150.0-alpha.8.sh")
LATEST_ALPHA_PROBE = '[[ "$(latest_alpha_tag)" == "$UPSTREAM_TAG" ]]'
LATEST_ALPHA_REPLACEMENT = (
    "printf 'Verified selected strict alpha: %s\\n' \"$UPSTREAM_TAG\"\n"
    'issue_update running "selected-alpha:${UPSTREAM_TAG}"'
)
ROLLBACK_TEST_MARKER = 'CURRENT_STEP="running-termux-regression-tests"\n'
ROLLBACK_TEST_PATCH = r'''CURRENT_STEP="repairing-rollback-listing-regression"
python3 - <<'PY'
from pathlib import Path

path = Path("scripts/termux/tests/run-tests")
text = path.read_text(encoding="utf-8")
old = (
    '  termux_list_installed_releases "$prefix" | grep -q "^\\* $sha2" '
    "|| fail 'release listing did not mark the active rollback target'"
)
new = (
    "  local installed_releases\n"
    '  installed_releases="$(termux_list_installed_releases "$prefix")"\n'
    '  grep -q "^\\* $sha2" <<<"$installed_releases" '
    "|| fail 'release listing did not mark the active rollback target'"
)
if text.count(old) != 1:
    raise SystemExit("rollback-listing assertion changed unexpectedly")
path.write_text(text.replace(old, new), encoding="utf-8")
PY

CURRENT_STEP="running-termux-regression-tests"
'''
SOURCE_READY_PROBE = (
    '[[ "$cleaned" == "true" ]]\n'
    'issue_update running "clean-exact-source-ready"'
)
SOURCE_READY_REPLACEMENT = (
    '[[ "$cleaned" == "true" ]]\n'
    'RELEASE_TAG="${RELEASE_TAG}-${SOURCE_SHA:0:10}"\n'
    'issue_update running "clean-exact-source-ready"'
)
BRANCH_CLEANUP_MARKER = 'CURRENT_STEP="cleaning-staging-branch"\n'
BRANCH_CLEANUP_PATCH = r'''CURRENT_STEP="cleaning-dependabot-branches"
while IFS= read -r ref; do
  [[ -n "$ref" ]] || continue
  branch="${ref#refs/heads/}"
  encoded_branch="$(jq -rn --arg value "$branch" '$value|@uri')"
  gh api --method DELETE \
    "/repos/${GITHUB_REPOSITORY}/git/refs/heads/${encoded_branch}" >/dev/null
done < <(
  gh api "/repos/${GITHUB_REPOSITORY}/git/matching-refs/heads/dependabot/" \
    --jq '.[].ref'
)

CURRENT_STEP="cleaning-staging-branch"
'''
UPSTREAM_TAG = "rust-v0.150.0-alpha.8"
UPSTREAM_COMMIT = "fcbdb57851be70192fd0c21faa9e529146e93ff1"
PACKAGE_VERSION = "0.150.0-alpha.8"
RELEASE_TAG = "termux-v0.150.0-alpha.8"
TRACKING_ISSUE = "77"
STALE_RUN_IDS = ("32212182486",)


def main() -> None:
    source = SOURCE.read_text(encoding="utf-8")
    if source.count(LATEST_ALPHA_PROBE) != 2:
        raise SystemExit("latest-alpha assertion changed unexpectedly")
    if source.count(ROLLBACK_TEST_MARKER) != 1:
        raise SystemExit("regression-test marker changed unexpectedly")
    if source.count(SOURCE_READY_PROBE) != 1:
        raise SystemExit("clean-source marker changed unexpectedly")
    if source.count(BRANCH_CLEANUP_MARKER) != 1:
        raise SystemExit("branch-cleanup marker changed unexpectedly")

    patched = source.replace(LATEST_ALPHA_PROBE, LATEST_ALPHA_REPLACEMENT)
    patched = patched.replace(ROLLBACK_TEST_MARKER, ROLLBACK_TEST_PATCH, 1)
    patched = patched.replace(SOURCE_READY_PROBE, SOURCE_READY_REPLACEMENT, 1)
    patched = patched.replace(BRANCH_CLEANUP_MARKER, BRANCH_CLEANUP_PATCH, 1)

    runtime = Path(tempfile.gettempdir()) / "update-alpha-0.150.0-alpha.8.sh"
    runtime.write_text(patched, encoding="utf-8")
    runtime.chmod(0o755)

    env = os.environ.copy()
    env.update(
        {
            "UPSTREAM_TAG": UPSTREAM_TAG,
            "UPSTREAM_COMMIT": UPSTREAM_COMMIT,
            "PACKAGE_VERSION": PACKAGE_VERSION,
            "RELEASE_TAG": RELEASE_TAG,
            "STAGING_BRANCH": "alpha-0.150.0-alpha.8-staging",
            "ISSUE_NUMBER": TRACKING_ISSUE,
        }
    )

    for run_id in STALE_RUN_IDS:
        subprocess.run(
            ["gh", "run", "cancel", run_id, "--repo", env["GITHUB_REPOSITORY"]],
            check=False,
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    subprocess.run(["bash", "-n", str(runtime)], check=True, env=env)
    subprocess.run(["bash", str(runtime)], check=True, env=env)


if __name__ == "__main__":
    main()
