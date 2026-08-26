#!/usr/bin/env bash
set -euo pipefail

tmp="${RUNNER_TEMP:?RUNNER_TEMP is required}/alpha13-maintenance-decoded.sh"
cat .github/scripts/alpha13-maintenance.part* | base64 --decode >"$tmp"
chmod +x "$tmp"
exec "$tmp"
