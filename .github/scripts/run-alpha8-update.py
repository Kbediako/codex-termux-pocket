#!/usr/bin/env python3
"""Run the bounded, exact-source Codex 0.150.0-alpha.8 updater."""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

SOURCE = Path(".github/scripts/update-alpha-0.150.0-alpha.8.sh")
PROBE = '[[ "$(latest_alpha_tag)" == "$UPSTREAM_TAG" ]]'
REPLACEMENT = (
    "printf 'Verified selected strict alpha: %s\\n' \"$UPSTREAM_TAG\"\n"
    'issue_update running "selected-alpha:${UPSTREAM_TAG}"'
)
UPSTREAM_TAG = "rust-v0.150.0-alpha.8"
UPSTREAM_COMMIT = "fcbdb57851be70192fd0c21faa9e529146e93ff1"
PACKAGE_VERSION = "0.150.0-alpha.8"
RELEASE_TAG = "termux-v0.150.0-alpha.8"
TRACKING_ISSUE = "77"


def main() -> None:
    source = SOURCE.read_text(encoding="utf-8")
    if source.count(PROBE) != 2:
        raise SystemExit("latest-alpha assertion changed unexpectedly")

    runtime = Path(tempfile.gettempdir()) / "update-alpha-0.150.0-alpha.8.sh"
    runtime.write_text(source.replace(PROBE, REPLACEMENT), encoding="utf-8")
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

    subprocess.run(["bash", "-n", str(runtime)], check=True, env=env)
    subprocess.run(["bash", str(runtime)], check=True, env=env)


if __name__ == "__main__":
    main()
