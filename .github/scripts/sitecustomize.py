"""Disposable latest-alpha bootstrap for the permanent release publisher."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

_DRIVER = Path(__file__).with_name("latest-alpha-release-driver.sh")
_MARKER = "CODEX_TERMUX_LATEST_ALPHA_DRIVER_ACTIVE"

if (
    os.environ.get("GITHUB_ACTIONS") == "true"
    and "validate-request" in sys.argv
    and _DRIVER.is_file()
    and os.environ.get(_MARKER) != "1"
):
    env = os.environ.copy()
    env[_MARKER] = "1"
    subprocess.run(["bash", str(_DRIVER)], check=True, env=env)
