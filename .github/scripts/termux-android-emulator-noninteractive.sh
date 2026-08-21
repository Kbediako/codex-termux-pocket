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

package_old = """pkg update -y
pkg install -y bash git curl ca-certificates coreutils findutils tar gzip nodejs proot termux-tools ripgrep
"""
package_new = """export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=a
apt-get update
apt-get -y \\
  -o Dpkg::Options::=--force-confdef \\
  -o Dpkg::Options::=--force-confold \\
  install bash git curl ca-certificates coreutils findutils tar gzip nodejs proot termux-tools ripgrep
"""
package_count = text.count(package_old)
if package_count != 1:
    raise SystemExit(
        f"expected exactly one Termux package bootstrap block, found {package_count}"
    )
text = text.replace(package_old, package_new, 1)

mirror_old = r'''git clone --bare "\${HOME}/codex-ci" "\${HOME}/codex-control-origin.git"
git --git-dir="\${HOME}/codex-control-origin.git" update-ref refs/heads/main "\${CONTROL_SHA}"
'''
mirror_new = mirror_old + r'''# The production installer requests a partial clone from GitHub. The CI-only
# local SSH mirror must advertise the same upload-pack filter capability or Git
# repeatedly falls back to individual unfiltered object requests inside ADB.
git --git-dir="\${HOME}/codex-control-origin.git" config uploadpack.allowFilter true
git --git-dir="\${HOME}/codex-control-origin.git" config uploadpack.allowAnySHA1InWant true
'''
mirror_count = text.count(mirror_old)
if mirror_count != 1:
    raise SystemExit(
        f"expected exactly one local Git mirror block, found {mirror_count}"
    )
text = text.replace(mirror_old, mirror_new, 1)

checkout_var_old = r'''export CODEX_SRC_DIR="\${HOME}/codex-ci"'''
checkout_var_new = r'''export CODEX_TERMUX_CHECKOUT_DIR="\${HOME}/codex-ci"'''
checkout_var_count = text.count(checkout_var_old)
if checkout_var_count != 1:
    raise SystemExit(
        f"expected exactly one legacy installer checkout variable, found {checkout_var_count}"
    )
text = text.replace(checkout_var_old, checkout_var_new, 1)

installer_old = r'''bash "\${CODEX_SRC_DIR}/scripts/termux/install-codex-termux"'''
installer_new = r'''bash "\${CODEX_TERMUX_CHECKOUT_DIR}/scripts/termux/install-codex-termux"'''
installer_count = text.count(installer_old)
if installer_count != 1:
    raise SystemExit(
        f"expected exactly one installer invocation through CODEX_SRC_DIR, found {installer_count}"
    )
text = text.replace(installer_old, installer_new, 1)

destination.write_text(text, encoding="utf-8")
PY

chmod 0755 "$patched_script"
exec "$patched_script"
