#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${ISSUE_NUMBER:?ISSUE_NUMBER is required}"

UPSTREAM_TAG="rust-v0.150.0-alpha.12"
UPSTREAM_COMMIT="7f3519b2286fdf0f8fbfcd13be4008911e68db2b"
PACKAGE_VERSION="0.150.0-alpha.12"
STAGING_BRANCH="alpha-0.150.0-alpha.12-staging"
TEMP_SCRIPT=".github/scripts/alpha12-maintenance.sh"

CURRENT_STEP="initializing"
MERGE_COMMIT=""
SOURCE_SHA=""
RELEASE_TAG=""
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
merge_commit=${MERGE_COMMIT}
source_sha=${SOURCE_SHA}
release_tag=${RELEASE_TAG}
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
  local exit_code="$?"
  issue_update failed "${CURRENT_STEP}:exit-${exit_code}"
  exit "$exit_code"
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

run_document() {
  local run_id="$1"
  gh run view "$run_id" --repo "$GITHUB_REPOSITORY" \
    --json databaseId,workflowName,headSha,event,status,conclusion,url,createdAt
}

latest_run_for_sha() {
  local workflow="$1"
  local sha="$2"
  gh run list --repo "$GITHUB_REPOSITORY" --workflow "$workflow" \
    --limit 100 \
    --json databaseId,headSha,event,status,conclusion,url,createdAt \
    --jq "map(select(.headSha == \"${sha}\")) | sort_by(.createdAt) | last | .databaseId // empty"
}

dispatch_and_find() {
  local workflow="$1"
  local sha="$2"
  shift 2
  local run_id

  run_id="$(latest_run_for_sha "$workflow" "$sha")"
  if [[ "$run_id" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$run_id"
    return 0
  fi

  gh workflow run "$workflow" --repo "$GITHUB_REPOSITORY" --ref main "$@"
  for _ in $(seq 1 90); do
    run_id="$(latest_run_for_sha "$workflow" "$sha")"
    if [[ "$run_id" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$run_id"
      return 0
    fi
    sleep 2
  done
  echo "::error::${workflow} did not expose a run for ${sha}" >&2
  return 1
}

wait_for_run() {
  local run_id="$1"
  local label="$2"
  local document status conclusion
  for _ in $(seq 1 900); do
    document="$(run_document "$run_id")"
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
  echo "::error::${label} run ${run_id} did not complete before timeout" >&2
  return 1
}

restore_from_base() {
  local base_sha="$1"
  local path="$2"
  git rm -rf --ignore-unmatch -- "$path" >/dev/null 2>&1 || true
  if git cat-file -e "${base_sha}:${path}" 2>/dev/null; then
    git checkout "$base_sha" -- "$path"
  fi
}

known_conflict() {
  case "$1" in
    .github/*|scripts/termux/*|README.md|AGENTS.md|PLANS.md|EXEC_PLAN*.md|EXECPLAN_*.md|docs/contributing.md|docs/termux-*.md|.prettierignore)
      return 0
      ;;
    codex-rs/Cargo.toml|codex-rs/Cargo.lock|MODULE.bazel.lock)
      return 0
      ;;
    codex-rs/arg0/src/lib.rs|codex-rs/cli/build.rs|codex-rs/cli/src/main.rs)
      return 0
      ;;
    codex-rs/linux-sandbox/src/landlock.rs|codex-rs/linux-sandbox/src/landlock_wrapper.rs|codex-rs/linux-sandbox/src/lib.rs|codex-rs/linux-sandbox/src/linux_run_main.rs|codex-rs/linux-sandbox/src/termux_read_only_seccomp.rs)
      return 0
      ;;
    codex-rs/sandboxing/src/bwrap.rs|codex-rs/tui/Cargo.toml|codex-rs/tui/src/clipboard_paste.rs|codex-rs/tui/src/onboarding/auth/headless_chatgpt_login.rs)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

CURRENT_STEP="verifying-start-state"
issue_update running "$CURRENT_STEP"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
BASE_SHA="$(git rev-parse HEAD)"
REMOTE_MAIN="$(git ls-remote origin refs/heads/main | awk '{print $1}')"
[[ "$BASE_SHA" == "$REMOTE_MAIN" ]]
[[ -z "$(git status --porcelain)" ]]

if git remote get-url upstream >/dev/null 2>&1; then
  git remote set-url upstream https://github.com/openai/codex.git
else
  git remote add upstream https://github.com/openai/codex.git
fi

CURRENT_STEP="fetching-exact-upstream-alpha"
git fetch --no-tags upstream \
  "refs/tags/${UPSTREAM_TAG}:refs/tags/${UPSTREAM_TAG}"
[[ "$(git rev-parse "${UPSTREAM_TAG}^{commit}")" == "$UPSTREAM_COMMIT" ]]
[[ "$(git ls-remote upstream refs/heads/latest-alpha-cli | awk '{print $1}')" == "$UPSTREAM_COMMIT" ]]

CURRENT_STEP="merging-exact-upstream-alpha"
git checkout -B "$STAGING_BRANCH"
git merge --no-ff --no-commit "$UPSTREAM_TAG" || true

mapfile -t unresolved < <(git diff --name-only --diff-filter=U)
unknown=()
for path in "${unresolved[@]}"; do
  if ! known_conflict "$path"; then
    unknown+=("$path")
    continue
  fi
  case "$path" in
    codex-rs/Cargo.toml|codex-rs/Cargo.lock|MODULE.bazel.lock)
      git checkout --theirs -- "$path" 2>/dev/null \
        || git rm -f --ignore-unmatch -- "$path"
      ;;
    *)
      git checkout --ours -- "$path" 2>/dev/null \
        || git rm -f --ignore-unmatch -- "$path"
      ;;
  esac
  git add -A -- "$path"
done
if (( ${#unknown[@]} > 0 )); then
  printf 'Unknown merge conflicts:\n' >&2
  printf '  %s\n' "${unknown[@]}" >&2
  issue_update failed "unknown-conflicts:$(IFS=,; echo "${unknown[*]}")"
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

CURRENT_STEP="updating-alpha-controls"
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

append_patch_audit \
  "termux: update to ${PACKAGE_VERSION}" \
  runtime-critical \
  "Merges the exact official ${PACKAGE_VERSION} source and reapplies the maintained Android and Termux runtime patch stack."

CURRENT_STEP="refreshing-and-validating-lockfile"
pushd codex-rs >/dev/null
if ! cargo metadata --locked --format-version=1 >/dev/null; then
  cargo metadata --format-version=1 >/dev/null
fi
cargo metadata --locked --format-version=1 >/dev/null
cargo fmt --all -- --check
cargo check --locked -p codex-linux-sandbox
popd >/dev/null

CURRENT_STEP="verifying-rusty-v8-inputs"
resolved_v8="$(python3 .github/scripts/rusty_v8_bazel.py resolved-v8-crate-version)"
locked_v8="$(sed -n 's/^rusty_v8_version=//p' scripts/termux/build-inputs.env)"
android_v8="$(
  sed -n 's/^[[:space:]]*RUSTY_V8_VERSION: "\([^"]*\)"/\1/p' \
    .github/workflows/termux-android-emulator.yml | head -n1
)"
[[ "$resolved_v8" == "$locked_v8" ]] || {
  issue_update failed "rusty-v8-build-input-mismatch:${locked_v8}-expected-${resolved_v8}"
  exit 1
}
[[ "$resolved_v8" == "$android_v8" ]] || {
  issue_update failed "rusty-v8-android-mismatch:${android_v8}-expected-${resolved_v8}"
  exit 1
}

CURRENT_STEP="running-arm64-fork-regressions"
export PREFIX=/data/data/com.termux/files/usr
export TERMUX_APK_RELEASE=F_DROID
sudo mkdir -p "$PREFIX/bin"
sudo ln -sfn /usr/bin/bash "$PREFIX/bin/bash"
bash scripts/termux/tests/run-tests
python3 .github/scripts/validate-termux-workflow-topology.py
git diff --check
if git grep -nE '^(<<<<<<<|>>>>>>>)' -- . ':!*.lock'; then
  echo "::error::merge conflict markers remain" >&2
  exit 1
fi

CURRENT_STEP="committing-merged-alpha"
git add -A
git diff --cached --quiet && {
  echo "::error::upstream merge produced no staged changes" >&2
  exit 1
}
git commit -m "termux: update to ${PACKAGE_VERSION}"
MERGE_COMMIT="$(git rev-parse HEAD)"
[[ "$(git rev-parse HEAD^2)" == "$UPSTREAM_COMMIT" ]]
git push origin "HEAD:refs/heads/${STAGING_BRANCH}"
git push origin HEAD:main
issue_update awaiting-direct-cleanup "merge-committed:${MERGE_COMMIT}"

CURRENT_STEP="waiting-for-direct-cleanup"
cleaned=false
for _ in $(seq 1 180); do
  git fetch origin main
  git reset --hard origin/main
  if [[ ! -e "$TEMP_SCRIPT" ]] \
    && ! grep -q 'alpha12-maintenance:' .github/workflows/blocking-ci.yml \
    && ! grep -q 'TEMP_MAINTENANCE_SCRIPT' .github/scripts/validate-termux-workflow-topology.py \
    && grep -q 'expected_package_version=0.150.0-alpha.12' scripts/termux/release-request.env; then
    python3 .github/scripts/validate-termux-workflow-topology.py
    cargo metadata --manifest-path codex-rs/Cargo.toml \
      --locked --format-version=1 >/dev/null
    [[ -z "$(git status --porcelain)" ]]
    SOURCE_SHA="$(git rev-parse HEAD)"
    git merge-base --is-ancestor "$UPSTREAM_COMMIT" "$SOURCE_SHA"
    cleaned=true
    break
  fi
  sleep 5
done
[[ "$cleaned" == "true" ]]
issue_update running "clean-source-ready:${SOURCE_SHA}"

CURRENT_STEP="dispatching-exact-source-gates"
FORK_CI_RUN_ID="$(dispatch_and_find blocking-ci.yml "$SOURCE_SHA")"
CONTROL_RUN_ID="$(dispatch_and_find termux-control-plane.yml "$SOURCE_SHA")"
SANDBOX_RUN_ID="$(dispatch_and_find termux-linux-sandbox.yml "$SOURCE_SHA")"
ARTIFACT_RUN_ID="$(
  dispatch_and_find termux-mobile-artifact.yml "$SOURCE_SHA" \
    -f source_ref="$SOURCE_SHA"
)"
ANDROID_RUN_ID="$(dispatch_and_find termux-android-emulator.yml "$SOURCE_SHA")"
issue_update running "$CURRENT_STEP"

CURRENT_STEP="waiting-for-exact-source-gates"
wait_for_run "$FORK_CI_RUN_ID" fork-ci
wait_for_run "$CONTROL_RUN_ID" control-plane
wait_for_run "$SANDBOX_RUN_ID" linux-sandbox
wait_for_run "$ARTIFACT_RUN_ID" arm64-artifact
wait_for_run "$ANDROID_RUN_ID" android-termux
issue_update running "exact-source-validation-passed"

CURRENT_STEP="rechecking-upstream-before-publication"
[[ "$(git ls-remote upstream refs/heads/latest-alpha-cli | awk '{print $1}')" == "$UPSTREAM_COMMIT" ]]

CURRENT_STEP="preparing-publication-request"
git fetch origin main
git reset --hard origin/main
[[ "$(git rev-parse HEAD)" == "$SOURCE_SHA" ]]
RELEASE_TAG="termux-v${PACKAGE_VERSION}-${SOURCE_SHA:0:10}"
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

append_patch_audit \
  "termux: stage ${PACKAGE_VERSION} publication" \
  tooling \
  "Records successful exact-source control-plane, ARM64, and Android validation evidence for publication."
append_patch_audit \
  "termux: promote ${RELEASE_TAG}" \
  tooling \
  "Promotes the byte-verified public release manifest after publication."

git add scripts/termux/release-publication.env scripts/termux/patch_audit.tsv
git commit -m "termux: stage ${PACKAGE_VERSION} publication"
PUBLICATION_SHA="$(git rev-parse HEAD)"
git push origin HEAD:main

CURRENT_STEP="waiting-for-release-publication"
RELEASE_RUN_ID="$(dispatch_and_find termux-release-request.yml "$PUBLICATION_SHA")"
issue_update running "$CURRENT_STEP"
wait_for_run "$RELEASE_RUN_ID" release-publication

CURRENT_STEP="verifying-live-release"
promoted=false
for _ in $(seq 1 120); do
  latest_tag="$(gh api "/repos/${GITHUB_REPOSITORY}/releases/latest" --jq .tag_name)"
  manifest_text="$(
    gh api "/repos/${GITHUB_REPOSITORY}/contents/scripts/termux/release-manifest.env?ref=main" \
      --jq .content | tr -d '\n' | base64 --decode
  )"
  if [[ "$latest_tag" == "$RELEASE_TAG" ]] \
    && grep -Fxq "release_tag=${RELEASE_TAG}" <<<"$manifest_text" \
    && grep -Fxq "head_sha=${SOURCE_SHA}" <<<"$manifest_text"; then
    promoted=true
    break
  fi
  sleep 5
done
[[ "$promoted" == "true" ]]

release_json="$(gh api "/repos/${GITHUB_REPOSITORY}/releases/tags/${RELEASE_TAG}")"
[[ "$(jq -r .tag_name <<<"$release_json")" == "$RELEASE_TAG" ]]
[[ "$(jq -r .target_commitish <<<"$release_json")" == "$SOURCE_SHA" ]]
[[ "$(jq -r .draft <<<"$release_json")" == "false" ]]
[[ "$(jq -r .prerelease <<<"$release_json")" == "false" ]]
expected_assets='["SHA256SUMS","codex-termux-aarch64-unknown-linux-musl.tar.gz","codex-termux-sbom.spdx.json","metadata.env","release-manifest.env"]'
[[ "$(jq -c '[.assets[].name] | sort' <<<"$release_json")" == "$expected_assets" ]]

git fetch origin main
PROMOTED_MAIN_SHA="$(git rev-parse origin/main)"

CURRENT_STEP="dispatching-post-promotion-checks"
POST_FORK_CI_RUN_ID="$(dispatch_and_find blocking-ci.yml "$PROMOTED_MAIN_SHA")"
POST_CONTROL_RUN_ID="$(dispatch_and_find termux-control-plane.yml "$PROMOTED_MAIN_SHA")"
CHANNEL_RUN_ID="$(dispatch_and_find termux-release-channel.yml "$PROMOTED_MAIN_SHA")"
GOVERNANCE_RUN_ID="$(dispatch_and_find termux-governance-audit.yml "$PROMOTED_MAIN_SHA")"
issue_update running "$CURRENT_STEP"

CURRENT_STEP="waiting-for-post-promotion-checks"
wait_for_run "$POST_FORK_CI_RUN_ID" post-fork-ci
wait_for_run "$POST_CONTROL_RUN_ID" post-control-plane
wait_for_run "$CHANNEL_RUN_ID" release-channel
wait_for_run "$GOVERNANCE_RUN_ID" governance-audit

CURRENT_STEP="cleaning-staging-branches"
for branch in alpha-0.150.0-alpha.8-staging "$STAGING_BRANCH"; do
  encoded="$(jq -rn --arg value "$branch" '$value|@uri')"
  if gh api "/repos/${GITHUB_REPOSITORY}/git/ref/heads/${encoded}" >/dev/null 2>&1; then
    gh api --method DELETE \
      "/repos/${GITHUB_REPOSITORY}/git/refs/heads/${encoded}" >/dev/null
  fi
done

issue_update completed "published-and-post-verified"
gh issue close "$ISSUE_NUMBER" --repo "$GITHUB_REPOSITORY" \
  --comment "Codex ${PACKAGE_VERSION} was merged from the exact official tag, validated on all required gates, published as GitHub Latest, and post-verified." >/dev/null
