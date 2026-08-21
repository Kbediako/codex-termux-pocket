#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

STATUS_BRANCH="${STATUS_BRANCH:-alpha-sync-status}"
STATUS_PATH="${STATUS_PATH:-.github/alpha-sync-status.env}"
UPSTREAM_TAG="${UPSTREAM_TAG:-rust-v0.149.0-alpha.7.1}"
UPSTREAM_COMMIT="${UPSTREAM_COMMIT:-0e015a7a0eef52047fea8ded24f8b32afbafd527}"
PACKAGE_VERSION="${PACKAGE_VERSION:-0.149.0-alpha.7.1}"

publish_status() {
  local state="$1"
  local detail="$2"
  local merge_sha="${3:-}"
  local file_sha status_file
  file_sha="$(
    gh api "/repos/${GITHUB_REPOSITORY}/contents/${STATUS_PATH}?ref=${STATUS_BRANCH}" --jq .sha
  )"
  status_file="$(mktemp)"
  cat >"$status_file" <<EOF
format_version=1
state=${state}
source_commit=${GITHUB_SHA}
upstream_tag=${UPSTREAM_TAG}
upstream_commit=${UPSTREAM_COMMIT}
detail=${detail}
merge_commit=${merge_sha}
run_id=${GITHUB_RUN_ID}
run_url=https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}
EOF
  gh api --method PUT \
    "/repos/${GITHUB_REPOSITORY}/contents/${STATUS_PATH}" \
    -f message="ci: alpha sync ${state} ${detail}" \
    -f content="$(base64 -w0 "$status_file")" \
    -f sha="$file_sha" \
    -f branch="$STATUS_BRANCH" >/dev/null
}

base_sha="$(git rev-parse HEAD)"
test "$base_sha" = "$GITHUB_SHA"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git remote add upstream https://github.com/openai/codex.git
git fetch --no-tags upstream \
  "refs/tags/${UPSTREAM_TAG}:refs/tags/${UPSTREAM_TAG}"
test "$(git rev-parse "${UPSTREAM_TAG}^{commit}")" = "$UPSTREAM_COMMIT"
publish_status running upstream-fetched || true

git merge --no-ff --no-commit -X ours "$UPSTREAM_TAG" || true

# Resolve remaining content or modify/delete conflicts in favour of the
# maintained Termux side. Non-conflicting upstream changes remain staged.
while IFS= read -r path; do
  if git checkout --ours -- "$path" 2>/dev/null; then
    git add -- "$path"
  else
    git rm -f --ignore-unmatch -- "$path"
  fi
done < <(git diff --name-only --diff-filter=U)

restore_from_base() {
  local path="$1"
  if git cat-file -e "${base_sha}:${path}" 2>/dev/null; then
    git checkout "$base_sha" -- "$path"
  else
    git rm -rf --ignore-unmatch -- "$path"
  fi
}

# These paths are fork-owned operating and release surfaces rather than
# upstream product source. They are restored exactly before validation.
for path in \
  .github/CODEOWNERS \
  .github/actions/setup-bazel-ci/action.yml \
  .github/assets \
  .github/repository-governance-status.json \
  .github/scripts \
  .github/termux-android-validation.json \
  .github/workflows \
  .prettierignore \
  AGENTS.md \
  EXECPLAN_voice.md \
  EXECPLAN_voice_porcu.md \
  EXEC_PLAN.md \
  EXEC_PLAN_TERMUX_INSTALL.md \
  EXEC_PLAN_mobile_build_acceleration.md \
  PLANS.md \
  README.md \
  docs/contributing.md \
  docs/termux-agent-safety.md \
  docs/termux-alpha-log.md \
  docs/termux-maintainer.md \
  docs/termux-mobile-update.md \
  scripts/termux; do
  restore_from_base "$path"
done
publish_status running merge-resolved || true

python3 - <<'PY'
from pathlib import Path
import re

path = Path("codex-rs/Cargo.toml")
text = path.read_text(encoding="utf-8")
pattern = re.compile(
    r'(?ms)(^\[workspace\.package\]\n.*?^version\s*=\s*")([^"]+)(")'
)
updated, count = pattern.subn(
    lambda match: match.group(1) + "0.149.0-alpha.7.1" + match.group(3),
    text,
    count=1,
)
if count != 1:
    raise SystemExit("failed to update workspace package version")
path.write_text(updated, encoding="utf-8")
PY

cat > scripts/termux/upstream-alpha.env <<EOF
format_version=1
tag=${UPSTREAM_TAG}
commit=${UPSTREAM_COMMIT}
EOF

cat > scripts/termux/release-request.env <<EOF
# Exact-source validation request for the protected alpha update.
format_version=3
source_mode=workflow-head
release_tag_prefix=termux-v2026.08.21-alpha.7.1
expected_package_version=${PACKAGE_VERSION}
EOF

cat >> scripts/termux/patch_audit.tsv <<'EOF'
subject	ci: stage upstream alpha sync	tooling	Temporary protected-main hook used to run the maintained upstream merge transaction.
subject	ci: restage observable upstream alpha sync	tooling	Temporary protected-main hook that exposed merge progress without adding a permanent workflow.
subject	ci: arm issue-triggered upstream alpha sync	tooling	Temporary issue-triggered hook prepared after connector-authored pushes did not schedule the merge job.
subject	ci: add observable alpha sync worker	tooling	Temporary merge worker used to regenerate the lockfile inside the repository CI environment.
subject	ci: fix alpha sync issue trigger	tooling	Temporary issue-reopen trigger that avoids YAML ambiguity in the maintenance event selector.
subject	ci: simulate Termux in alpha sync tests	tooling	Runs the existing helper fixtures under the same simulated Termux PREFIX used by the permanent control-plane workflow.
subject	termux: update to 0.149.0-alpha.7.1	runtime-critical	Merges the official alpha.7.1 source and reapplies the maintained Android and Termux runtime patch stack.
EOF

publish_status running resolving-lockfile || true
cargo metadata --manifest-path codex-rs/Cargo.toml \
  --format-version=1 >/dev/null
cargo metadata --manifest-path codex-rs/Cargo.toml \
  --locked --format-version=1 >/dev/null

publish_status running running-regression-tests || true
cargo fmt --manifest-path codex-rs/Cargo.toml --all -- --check
export PREFIX=/data/data/com.termux/files/usr
export TERMUX_APK_RELEASE=F_DROID
sudo mkdir -p "$PREFIX/bin"
sudo ln -sfn /usr/bin/bash "$PREFIX/bin/bash"
bash scripts/termux/tests/run-tests
git diff --check

git add -- \
  codex-rs/Cargo.toml \
  codex-rs/Cargo.lock \
  scripts/termux/upstream-alpha.env \
  scripts/termux/release-request.env \
  scripts/termux/patch_audit.tsv

git diff --cached --quiet && {
  echo "::error::Upstream merge produced no staged update"
  exit 1
}
git commit -m "termux: update to ${PACKAGE_VERSION}"
merge_sha="$(git rev-parse HEAD)"
test "$(git rev-parse HEAD^2)" = "$UPSTREAM_COMMIT"
echo "merge_sha=${merge_sha}" >> "$GITHUB_OUTPUT"
publish_status running pushing-main "$merge_sha" || true
git push origin HEAD:main
