#!/usr/bin/env bash
set -euo pipefail

base_script="${RUNNER_TEMP:?RUNNER_TEMP is required}/alpha1515-base.sh"
runtime_script="$RUNNER_TEMP/alpha1515-maintenance-runtime.sh"
cat .github/scripts/alpha1515-maintenance.part* | base64 --decode >"$base_script"

python3 - "$base_script" "$runtime_script" <<'PY'
from pathlib import Path
import re
import sys

source_path = Path(sys.argv[1])
runtime_path = Path(sys.argv[2])
source = source_path.read_text(encoding="utf-8")

replacements = (
    ("rust-v0.150.0-alpha.13", "rust-v0.151.0-alpha.5"),
    ("c080ad22b3744f3cefcdeeb134ee17c0093d16a1", "e6e0c4fb8c0340800f4066c50e849149e4ecd912"),
    ("0.150.0-alpha.13", "0.151.0-alpha.5"),
    ("alpha13", "alpha1515"),
    ("alpha.13", "0.151.0-alpha.5"),
)
for old, new in replacements:
    source = source.replace(old, new)

old_check = r'''[[ "$(git ls-remote upstream refs/heads/latest-alpha-cli | awk '{print $1}')" == "$UPSTREAM_COMMIT" ]]'''
new_check = r'''[[ "$(git ls-remote upstream "refs/tags/${UPSTREAM_TAG}^{}" | awk '{print $1}')" == "$UPSTREAM_COMMIT" ]]'''
if source.count(old_check) != 2:
    raise SystemExit("unexpected moving-branch check count")
source = source.replace(old_check, new_check)

source = re.sub(
    r'\nif gh issue view 85 --repo "\$GITHUB_REPOSITORY" >/dev/null 2>&1; then\n'
    r'  gh issue close 85 --repo "\$GITHUB_REPOSITORY" \\\n'
    r'    --comment "Superseded by the completed 0\.151\.0-alpha\.5 publication\." >/dev/null \|\| true\n'
    r'fi\n?',
    '\n',
    source,
)

audit_needle = '''append_patch_audit() {
  local subject="$1"
  local classification="$2"
  local reason="$3"
  local line
  line=$'subject\\t'"${subject}"$'\\t'"${classification}"$'\\t'"${reason}"
  grep -Fqx "$line" scripts/termux/patch_audit.tsv \\
    || printf '%s\\n' "$line" >> scripts/termux/patch_audit.tsv
}
'''
restore_function = audit_needle + '''
restore_from_base() {
  local base_sha="$1"
  local path="$2"
  git rm -rf --ignore-unmatch -- "$path" >/dev/null 2>&1 || true
  if git cat-file -e "${base_sha}:${path}" 2>/dev/null; then
    git checkout "$base_sha" -- "$path"
  fi
}
'''
if source.count(audit_needle) != 1:
    raise SystemExit("patch-audit insertion point changed")
source = source.replace(audit_needle, restore_function)

start_needle = '''git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
BASE_SHA="$(git rev-parse HEAD)"
'''
start_replacement = '''git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
gh api --method POST \\
  "/repos/${GITHUB_REPOSITORY}/actions/runs/32212182486/cancel" \\
  >/dev/null 2>&1 || true
BASE_SHA="$(git rev-parse HEAD)"
'''
if source.count(start_needle) != 1:
    raise SystemExit("start-state insertion point changed")
source = source.replace(start_needle, start_replacement)

merge_needle = '''[[ -z "$(git diff --name-only --diff-filter=U)" ]]

CURRENT_STEP="updating-alpha-controls"
'''
restore_block = '''[[ -z "$(git diff --name-only --diff-filter=U)" ]]

CURRENT_STEP="restoring-fork-owned-surface"
for path in \\
  .github \\
  scripts/termux \\
  README.md \\
  AGENTS.md \\
  PLANS.md \\
  EXECPLAN_voice.md \\
  EXECPLAN_voice_porcu.md \\
  EXEC_PLAN.md \\
  EXEC_PLAN_TERMUX_INSTALL.md \\
  EXEC_PLAN_mobile_build_acceleration.md \\
  .prettierignore \\
  docs/contributing.md \\
  docs/termux-agent-safety.md \\
  docs/termux-alpha-log.md \\
  docs/termux-maintainer.md \\
  docs/termux-mobile-update.md; do
  restore_from_base "$BASE_SHA" "$path"
done

CURRENT_STEP="updating-alpha-controls"
'''
if source.count(merge_needle) != 1:
    raise SystemExit("fork-surface insertion point changed")
source = source.replace(merge_needle, restore_block)

controls_needle = '''cat > scripts/termux/release-request.env <<EOF
# Exact-source validation request for Codex ${PACKAGE_VERSION}.
format_version=3
source_mode=workflow-head
release_tag_prefix=termux-v${PACKAGE_VERSION}
expected_package_version=${PACKAGE_VERSION}
EOF

append_patch_audit \\
'''
controls_replacement = '''cat > scripts/termux/release-request.env <<EOF
# Exact-source validation request for Codex ${PACKAGE_VERSION}.
format_version=3
source_mode=workflow-head
release_tag_prefix=termux-v${PACKAGE_VERSION}
expected_package_version=${PACKAGE_VERSION}
EOF

workspace_version="$(
  awk '
    /^\\[workspace\\.package\\]$/ { in_package=1; next }
    /^\\[/ && in_package { exit }
    in_package && /^version[[:space:]]*=/ {
      value=$0
      sub(/^[^=]*=[[:space:]]*"/, "", value)
      sub(/".*$/, "", value)
      print value
      exit
    }
  ' codex-rs/Cargo.toml
)"
[[ "$workspace_version" == "$PACKAGE_VERSION" ]]

append_patch_audit \\
'''
if source.count(controls_needle) != 1:
    raise SystemExit("release-control insertion point changed")
source = source.replace(controls_needle, controls_replacement)

cleanup_needle = '''  if [[ ! -e "$TEMP_SCRIPT" ] \\
    && ! grep -q 'alpha1515-maintenance:' .github/workflows/blocking-ci.yml \\
'''
cleanup_replacement = '''  if [[ ! -e "$TEMP_SCRIPT" ] \\
    && ! compgen -G ".github/scripts/alpha1515-maintenance.part*" >/dev/null \\
    && ! grep -q 'alpha1515-maintenance:' .github/workflows/blocking-ci.yml \\
'''
if source.count(cleanup_needle) != 1:
    raise SystemExit("direct-cleanup insertion point changed")
source = source.replace(cleanup_needle, cleanup_replacement)

branches_needle = '''for branch in \\
  alpha-0.150.0-alpha.8-staging \\
  alpha-0.150.0-alpha.12-staging \\
  "$STAGING_BRANCH"; do
'''
branches_replacement = '''for branch in \\
  alpha-0.150.0-alpha.8-staging \\
  alpha-0.150.0-alpha.12-staging \\
  alpha-0.150.0-alpha.13-staging \\
  "$STAGING_BRANCH"; do
'''
if source.count(branches_needle) != 1:
    raise SystemExit("branch-cleanup insertion point changed")
source = source.replace(branches_needle, branches_replacement)

if "latest-alpha-cli" in source or "alpha13" in source:
    raise SystemExit("stale alpha transaction token remains")
if "0.151.0-alpha.5" not in source or "e6e0c4fb8c0340800f4066c50e849149e4ecd912" not in source:
    raise SystemExit("exact alpha identity missing")

runtime_path.write_text(source, encoding="utf-8")
PY

bash -n "$runtime_script"
if [[ "${ALPHA1515_TRANSFORM_ONLY:-}" == "1" ]]; then
  cat "$runtime_script"
  exit 0
fi
chmod +x "$runtime_script"
exec "$runtime_script"
