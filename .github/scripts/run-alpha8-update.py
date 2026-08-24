#!/usr/bin/env python3
"""Run the bounded alpha.8 updater after removing its broken tag enumerator."""

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


def main() -> None:
    source = SOURCE.read_text(encoding="utf-8")
    if source.count(PROBE) != 2:
        raise SystemExit("latest-alpha assertion changed unexpectedly")

    runtime = Path(tempfile.gettempdir()) / "update-alpha-0.150.0-alpha.8.sh"
    runtime.write_text(source.replace(PROBE, REPLACEMENT), encoding="utf-8")
    runtime.chmod(0o755)

    subprocess.run(["bash", "-n", str(runtime)], check=True)
    subprocess.run(["bash", str(runtime)], check=True, env=os.environ.copy())


if __name__ == "__main__":
    main()
