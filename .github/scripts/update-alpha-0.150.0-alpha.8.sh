#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${ISSUE_NUMBER:?ISSUE_NUMBER is required}"
: "${UPSTREAM_TAG:?UPSTREAM_TAG is required}"
: "${UPSTREAM_COMMIT:?UPSTREAM_COMMIT is required}"
: "${PACKAGE_VERSION:?PACKAGE_VERSION is required}"
: "${RELEASE_TAG:?RELEASE_TAG is required}"
: "${STAGING_BRANCH:?STAGING_BRANCH is required}"

TEMP_SCRIPT=".github/scripts/update-alpha-0.150.0-alpha.8.sh"
CURRENT_STEP="initializing"
SOURCE_SHA=""
CANDIDATE_SHA=""
FORK_CI_RUN_ID=""
CONTROL_RUN_ID=""
SANDBOX_RUN_ID=""
ARTIFACT_RUN_ID=""
ANDROID_RUN_ID=""
RELEASE_RUN_ID=""
POST_FORK_CI_RUN_ID=""
POST_CONTROL_RUN_ID=""
CHANNEL_RUN_ID=""
GOVERNANCE_RUN_ID=""

issue_update() {
  local state="$1"
  local detail="$2"
  local body
  body="$(cat <<EOF
state=${state}
detail=${detail}
orchestrator_run_id=${GITHUB_RUN_ID}
orchestrator_run_url=https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}
upstream_tag=${UPSTREAM_TAG}
upstream_commit=${UPSTREAM_COMMIT}
package_version=${PACKAGE_VERSION}
release_tag=${RELEASE_TAG}
candidate_sha=${CANDIDATE_SHA}
source_sha=${SOURCE_SHA}
fork_ci_run_id=${FORK_CI_RUN_ID}
control_run_id=${CONTROL_RUN_ID}
sandbox_run_id=${SANDBOX_RUN_ID}
artifact_run_id=${ARTIFACT_RUN_ID}
android_run_id=${ANDROID_RUN_ID}
release_run_id=${RELEASE_RUN_ID}
post_fork_ci_run_id=${POST_FORK_CI_RUN_ID}
post_control_run_id=${POST_CONTROL_RUN_ID}
release_channel_run_id=${CHANNEL_RUN_ID}
governance_run_id=${GOVERNANCE_RUN_ID}
EOF
)"
  gh api --method PATCH \
    "/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}" \
    -f body="$body" >/dev/null || true
}

on_error() {
  local code="$?"
  issue_update failed "${CURRENT_STEP}:exit-${code}"
  exit "$code"
}
trap on_error ERR

append_patch_audit() {
  local subject="$1"
  local classification="$2"
  local reason="$3"
  local line
  line=$'subject\t'"${subject}"$'\t'"${classification}"$'\t'"${reason}"
  grep -Fqx "$line" scripts/termux/patch_audit.tsv \
    || printf '%s\n' "$line" >> scripts/termux/patch_audit.tsv
}

restore_from_base() {
  local base="$1"
  local path="$2"
  git rm -rf --ignore-unmatch -- "$path" >/dev/null 2>&1 || true
  if git cat-file -e "${base}:${path}" 2>/dev/null; then
    git checkout "$base" -- "$path"
  fi
}

latest_alpha_tag() {
  git ls-remote --tags --refs upstream 'refs/tags/rust-v*-alpha.*' \
    | awk '{sub("^refs/tags/", "", $2); print $2}' \
    | grep -E '^rust-v[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+(\.[0-9]+)?$' \
    | sort -V \
    | tail -n 1
}

run_json() {
  local run_id="$1"
  gh run view "$run_id" --repo "$GITHUB_REPOSITORY" \
    --json databaseId,workflowName,headSha,event,status,conclusion,url
}

find_or_dispatch() {
  local workflow="$1"
  local expected_sha="$2"
  shift 2
  local runs run_id

  for _ in $(seq 1 12); do
    runs="$(
      gh run list --repo "$GITHUB_REPOSITORY" --workflow "$workflow" \
        --limit 100 \
        --json databaseId,headSha,createdAt,event,status,conclusion,url,workflowName
    )"
    run_id="$(
      jq -r --arg sha "$expected_sha" \
        '[.[] | select(.headSha == $sha and (.event == "push" or .event == "workflow_dispatch"))]
         | sort_by(.createdAt) | last | .databaseId // empty' <<<"$runs"
    )"
    if [[ "$run_id" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$run_id"
      return 0
    fi
    sleep 2
  done

  local started_at
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  gh workflow run "$workflow" --repo "$GITHUB_REPOSITORY" --ref main "$@" >/dev/null

  for _ in $(seq 1 90); do
    runs="$(
      gh run list --repo "$GITHUB_REPOSITORY" --workflow "$workflow" \
        --event workflow_dispatch --limit 100 \
        --json databaseId,headSha,createdAt,event,status,conclusion,url,workflowName
    )"
    run_id="$(
      jq -r --arg sha "$expected_sha" --arg started "$started_at" \
        '[.[] | select(.headSha == $sha and .createdAt >= $started)]
         | sort_by(.createdAt) | last | .databaseId // empty' <<<"$runs"
    )"
    if [[ "$run_id" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$run_id"
      return 0
    fi
    sleep 2
  done

  echo "::error::${workflow} did not expose a run for ${expected_sha}" >&2
  return 1
}

wait_for_run() {
  local run_id="$1"
  local label="$2"
  local document status conclusion
  for _ in $(seq 1 720); do
    document="$(run_json "$run_id")"
    status="$(jq -r .status <<<"$document")"
    if [[ "$status" == "completed" ]]; then
      conclusion="$(jq -r '.conclusion // "missing"' <<<"$document")"
      if [[ "$conclusion" != "success" ]]; then
        echo "::error::${label} run ${run_id} concluded ${conclusion}" >&2
        printf '%s\n' "$document" >&2
        return 1
      fi
      return 0
    fi
    sleep 10
  done
  echo "::error::${label} run ${run_id} timed out" >&2
  return 1
}

CURRENT_STEP="verifying-live-start-state"
issue_update running "$CURRENT_STEP"
BASE_SHA="$(git rev-parse HEAD)"
REMOTE_MAIN="$(git ls-remote origin refs/heads/main | awk '{print $1}')"
[[ "$BASE_SHA" == "$REMOTE_MAIN" ]]
[[ -z "$(git status --porcelain)" ]]

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git checkout -B "$STAGING_BRANCH"

if git remote get-url upstream >/dev/null 2>&1; then
  git remote set-url upstream https://github.com/openai/codex.git
else
  git remote add upstream https://github.com/openai/codex.git
fi

CURRENT_STEP="fetching-and-verifying-upstream-alpha"
git fetch --no-tags upstream "refs/tags/${UPSTREAM_TAG}:refs/tags/${UPSTREAM_TAG}"
[[ "$(git rev-parse "${UPSTREAM_TAG}^{commit}")" == "$UPSTREAM_COMMIT" ]]
[[ "$(latest_alpha_tag)" == "$UPSTREAM_TAG" ]]
issue_update running "$CURRENT_STEP"

CURRENT_STEP="merging-upstream-alpha"
git merge --no-ff --no-commit -X ours "$UPSTREAM_TAG" || true

unknown_conflicts=()
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  case "$path" in
    .github/*|scripts/termux/*|README.md|AGENTS.md|PLANS.md|EXEC_PLAN*.md|EXECPLAN_*.md|docs/contributing.md|docs/termux-*.md|.prettierignore)
      git checkout --ours -- "$path" 2>/dev/null || git rm -f --ignore-unmatch -- "$path"
      git add -- "$path" 2>/dev/null || true
      ;;
    codex-rs/Cargo.lock|codex-rs/Cargo.toml)
      git checkout --theirs -- "$path" 2>/dev/null || git rm -f --ignore-unmatch -- "$path"
      git add -- "$path" 2>/dev/null || true
      ;;
    *)
      unknown_conflicts+=("$path")
      ;;
  esac
done < <(git diff --name-only --diff-filter=U)

if (( ${#unknown_conflicts[@]} > 0 )); then
  printf 'Unknown merge conflicts:\n' >&2
  printf '  %s\n' "${unknown_conflicts[@]}" >&2
  issue_update failed "unknown-conflicts:$(IFS=,; echo "${unknown_conflicts[*]}")"
  exit 1
fi
[[ -z "$(git diff --name-only --diff-filter=U)" ]]

CURRENT_STEP="restoring-fork-owned-surface"
for path in \
  .github \
  scripts/termux \
  README.md \
  AGENTS.md \
  PLANS.md \
  EXECPLAN_voice.md \
  EXECPLAN_voice_porcu.md \
  EXEC_PLAN.md \
  EXEC_PLAN_TERMUX_INSTALL.md \
  EXEC_PLAN_mobile_build_acceleration.md \
  .prettierignore \
  docs/contributing.md \
  docs/termux-agent-safety.md \
  docs/termux-alpha-log.md \
  docs/termux-maintainer.md \
  docs/termux-mobile-update.md; do
  restore_from_base "$BASE_SHA" "$path"
done

CURRENT_STEP="updating-version-and-release-controls"
python3 - "$PACKAGE_VERSION" <<'PY'
from pathlib import Path
import re
import sys

path = Path("codex-rs/Cargo.toml")
version = sys.argv[1]
text = path.read_text(encoding="utf-8")
pattern = re.compile(
    r'(?ms)(^\[workspace\.package\]\n.*?^version[ \t]*=[ \t]*")([^"]+)(")'
)
updated, count = pattern.subn(
    lambda match: match.group(1) + version + match.group(3),
    text,
    count=1,
)
if count != 1:
    raise SystemExit("failed to set workspace package version")
path.write_text(updated, encoding="utf-8")
PY

cat > scripts/termux/upstream-alpha.env <<EOF
format_version=1
tag=${UPSTREAM_TAG}
commit=${UPSTREAM_COMMIT}
EOF

cat > scripts/termux/release-request.env <<EOF
# Exact-source validation request for Codex ${PACKAGE_VERSION}.
format_version=3
source_mode=workflow-head
release_tag_prefix=${RELEASE_TAG}
expected_package_version=${PACKAGE_VERSION}
EOF

append_patch_audit \
  "termux: update to ${PACKAGE_VERSION}" \
  runtime-critical \
  "Merges the exact official ${PACKAGE_VERSION} source and reapplies the maintained Android and Termux runtime patch stack."
append_patch_audit \
  "termux: stage ${PACKAGE_VERSION} publication" \
  tooling \
  "Records successful exact-source control-plane, ARM64, and Android validation evidence for publication."
append_patch_audit \
  "termux: promote ${RELEASE_TAG}" \
  tooling \
  "Promotes the byte-verified public release manifest after publication."

CURRENT_STEP="refreshing-and-validating-lockfile"
cargo metadata --manifest-path codex-rs/Cargo.toml --format-version=1 >/dev/null
cargo metadata --manifest-path codex-rs/Cargo.toml --locked --format-version=1 >/dev/null
(
  cd codex-rs
  cargo fmt --all -- --check
  cargo check --locked -p codex-linux-sandbox
)

CURRENT_STEP="checking-rusty-v8-inputs"
resolved_v8="$(python3 .github/scripts/rusty_v8_bazel.py resolved-v8-crate-version)"
locked_v8="$(sed -n 's/^rusty_v8_version=//p' scripts/termux/build-inputs.env)"
android_v8="$(
  sed -n 's/^[[:space:]]*RUSTY_V8_VERSION: "\([^"]*\)"/\1/p' \
    .github/workflows/termux-android-emulator.yml | head -n1
)"
[[ "$resolved_v8" == "$locked_v8" ]]
[[ "$resolved_v8" == "$android_v8" ]]

CURRENT_STEP="running-termux-regression-tests"
export PREFIX=/data/data/com.termux/files/usr
export TERMUX_APK_RELEASE=F_DROID
sudo mkdir -p "$PREFIX/bin"
sudo ln -sfn /usr/bin/bash "$PREFIX/bin/bash"
bash scripts/termux/tests/run-tests
git diff --check
if git grep -nE '^(<<<<<<<|>>>>>>>)' -- . ':!*.lock'; then
  echo "::error::merge conflict markers remain" >&2
  exit 1
fi

CURRENT_STEP="committing-staged-source"
git add -A
git diff --cached --quiet && {
  echo "::error::upstream alpha merge produced no staged changes" >&2
  exit 1
}
git commit -m "termux: update to ${PACKAGE_VERSION}"
CANDIDATE_SHA="$(git rev-parse HEAD)"
[[ "$(git rev-parse HEAD^2)" == "$UPSTREAM_COMMIT" ]]
git push origin "HEAD:refs/heads/${STAGING_BRANCH}"
issue_update awaiting-cleanup "candidate-ready:${CANDIDATE_SHA}"

CURRENT_STEP="waiting-for-direct-cleanup"
cleaned=false
for _ in $(seq 1 180); do
  git fetch origin main
  git reset --hard origin/main
  if [[ ! -e "$TEMP_SCRIPT" ]] \
    && ! grep -q 'update-alpha-0.150.0-alpha.8' .github/workflows/blocking-ci.yml \
    && ! grep -q 'update-latest-alpha:' .github/workflows/blocking-ci.yml; then
    python3 .github/scripts/validate-termux-workflow-topology.py
    cargo metadata --manifest-path codex-rs/Cargo.toml \
      --locked --format-version=1 >/dev/null
    [[ -z "$(git status --porcelain)" ]]
    SOURCE_SHA="$(git rev-parse HEAD)"
    git merge-base --is-ancestor "$CANDIDATE_SHA" "$SOURCE_SHA"
    git merge-base --is-ancestor "$UPSTREAM_COMMIT" "$SOURCE_SHA"
    cleaned=true
    break
  fi
  sleep 5
done
[[ "$cleaned" == "true" ]]
issue_update running "clean-exact-source-ready"

CURRENT_STEP="dispatching-exact-source-validation"
FORK_CI_RUN_ID="$(find_or_dispatch blocking-ci.yml "$SOURCE_SHA")"
CONTROL_RUN_ID="$(find_or_dispatch termux-control-plane.yml "$SOURCE_SHA")"
SANDBOX_RUN_ID="$(find_or_dispatch termux-linux-sandbox.yml "$SOURCE_SHA")"
ARTIFACT_RUN_ID="$(
  find_or_dispatch termux-mobile-artifact.yml "$SOURCE_SHA" \
    -f source_ref="$SOURCE_SHA"
)"
ANDROID_RUN_ID="$(find_or_dispatch termux-android-emulator.yml "$SOURCE_SHA")"
issue_update running "$CURRENT_STEP"

CURRENT_STEP="waiting-for-exact-source-validation"
wait_for_run "$FORK_CI_RUN_ID" fork-ci
wait_for_run "$CONTROL_RUN_ID" control-plane
wait_for_run "$SANDBOX_RUN_ID" linux-sandbox
wait_for_run "$ARTIFACT_RUN_ID" arm64-artifact
wait_for_run "$ANDROID_RUN_ID" android-termux
issue_update running "exact-source-validation-passed"

CURRENT_STEP="rechecking-latest-alpha-before-publication"
git fetch --no-tags upstream "refs/tags/${UPSTREAM_TAG}:refs/tags/${UPSTREAM_TAG}"
[[ "$(latest_alpha_tag)" == "$UPSTREAM_TAG" ]]
[[ "$(git rev-parse "${UPSTREAM_TAG}^{commit}")" == "$UPSTREAM_COMMIT" ]]

CURRENT_STEP="preparing-publication-evidence"
git fetch origin main
git reset --hard origin/main
[[ "$(git rev-parse HEAD)" == "$SOURCE_SHA" ]]
if gh api "/repos/${GITHUB_REPOSITORY}/git/ref/tags/${RELEASE_TAG}" >/dev/null 2>&1; then
  echo "::error::release tag already exists: ${RELEASE_TAG}" >&2
  exit 1
fi
if gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  echo "::error::release already exists: ${RELEASE_TAG}" >&2
  exit 1
fi

cat > scripts/termux/release-publication.env <<EOF
# Exact validated source and publication evidence.
format_version=1
source_sha=${SOURCE_SHA}
release_tag=${RELEASE_TAG}
expected_package_version=${PACKAGE_VERSION}
expected_codex_version=codex-cli ${SOURCE_SHA:0:7}
control_run_id=${CONTROL_RUN_ID}
artifact_run_id=${ARTIFACT_RUN_ID}
android_run_id=${ANDROID_RUN_ID}
EOF

git add scripts/termux/release-publication.env
git commit -m "termux: stage ${PACKAGE_VERSION} publication"
git push origin HEAD:main
PUBLICATION_CONTROL_SHA="$(git rev-parse HEAD)"
issue_update running "$CURRENT_STEP"

CURRENT_STEP="publishing-validated-release"
RELEASE_RUN_ID="$(
  find_or_dispatch termux-release-request.yml "$PUBLICATION_CONTROL_SHA"
)"
issue_update running "$CURRENT_STEP"
wait_for_run "$RELEASE_RUN_ID" release-publication

CURRENT_STEP="verifying-live-release-and-manifest"
git fetch origin main
PROMOTED_MAIN_SHA="$(git rev-parse origin/main)"
release_json="$(
  gh api "/repos/${GITHUB_REPOSITORY}/releases/tags/${RELEASE_TAG}"
)"
latest_json="$(gh api "/repos/${GITHUB_REPOSITORY}/releases/latest")"
[[ "$(jq -r .tag_name <<<"$release_json")" == "$RELEASE_TAG" ]]
[[ "$(jq -r .target_commitish <<<"$release_json")" == "$SOURCE_SHA" ]]
[[ "$(jq -r .draft <<<"$release_json")" == "false" ]]
[[ "$(jq -r .prerelease <<<"$release_json")" == "false" ]]
[[ "$(jq -r .tag_name <<<"$latest_json")" == "$RELEASE_TAG" ]]
expected_assets='["SHA256SUMS","codex-termux-aarch64-unknown-linux-musl.tar.gz","codex-termux-sbom.spdx.json","metadata.env","release-manifest.env"]'
[[ "$(jq -c '[.assets[].name] | sort' <<<"$release_json")" == "$expected_assets" ]]

manifest_text="$(
  gh api \
    "/repos/${GITHUB_REPOSITORY}/contents/scripts/termux/release-manifest.env?ref=main" \
    --jq .content | tr -d '\n' | base64 --decode
)"
grep -Fx "release_tag=${RELEASE_TAG}" <<<"$manifest_text"
grep -Fx "head_sha=${SOURCE_SHA}" <<<"$manifest_text"
grep -Fx "codex_version=codex-cli ${SOURCE_SHA:0:7}" <<<"$manifest_text"

CURRENT_STEP="dispatching-post-promotion-checks"
POST_FORK_CI_RUN_ID="$(find_or_dispatch blocking-ci.yml "$PROMOTED_MAIN_SHA")"
POST_CONTROL_RUN_ID="$(
  find_or_dispatch termux-control-plane.yml "$PROMOTED_MAIN_SHA"
)"
CHANNEL_RUN_ID="$(
  find_or_dispatch termux-release-channel.yml "$PROMOTED_MAIN_SHA"
)"
GOVERNANCE_RUN_ID="$(
  find_or_dispatch termux-governance-audit.yml "$PROMOTED_MAIN_SHA"
)"
issue_update running "$CURRENT_STEP"

CURRENT_STEP="waiting-for-post-promotion-checks"
wait_for_run "$POST_FORK_CI_RUN_ID" post-fork-ci
wait_for_run "$POST_CONTROL_RUN_ID" post-control-plane
wait_for_run "$CHANNEL_RUN_ID" release-channel
wait_for_run "$GOVERNANCE_RUN_ID" governance-audit

CURRENT_STEP="cleaning-staging-branch"
encoded_branch="$(jq -rn --arg value "$STAGING_BRANCH" '$value|@uri')"
if gh api \
  "/repos/${GITHUB_REPOSITORY}/git/ref/heads/${encoded_branch}" >/dev/null 2>&1; then
  gh api --method DELETE \
    "/repos/${GITHUB_REPOSITORY}/git/refs/heads/${encoded_branch}" >/dev/null
fi

issue_update completed "published-and-post-verified"
gh issue close "$ISSUE_NUMBER" --repo "$GITHUB_REPOSITORY" \
  --comment "Codex ${PACKAGE_VERSION} was merged from ${UPSTREAM_TAG}, validated on the exact cleaned source, published as GitHub Latest, and post-verified." >/dev/null

echo "source_sha=${SOURCE_SHA}" >> "$GITHUB_OUTPUT"
echo "release_tag=${RELEASE_TAG}" >> "$GITHUB_OUTPUT"
echo "release_run_id=${RELEASE_RUN_ID}" >> "$GITHUB_OUTPUT"
echo "promoted_main_sha=${PROMOTED_MAIN_SHA}" >> "$GITHUB_OUTPUT"
