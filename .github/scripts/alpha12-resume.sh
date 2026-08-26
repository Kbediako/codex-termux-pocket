#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${ISSUE_NUMBER:?ISSUE_NUMBER is required}"

UPSTREAM_TAG="rust-v0.150.0-alpha.12"
UPSTREAM_COMMIT="7f3519b2286fdf0f8fbfcd13be4008911e68db2b"
PACKAGE_VERSION="0.150.0-alpha.12"
SOURCE_SHA="db1c194f3ade28d3a23e51eb0464c41a8b0592df"
STAGING_BRANCH="alpha-0.150.0-alpha.12-staging"

FORK_CI_RUN_ID="32960914324"
CONTROL_RUN_ID="32960914390"
SANDBOX_RUN_ID="32960931730"
ARTIFACT_RUN_ID="32960938542"
ANDROID_RUN_ID="32960914298"

CURRENT_STEP="initializing"
RELEASE_TAG=""
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
resume_run_id=${GITHUB_RUN_ID}
resume_run_url=https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}
upstream_tag=${UPSTREAM_TAG}
upstream_commit=${UPSTREAM_COMMIT}
package_version=${PACKAGE_VERSION}
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
  gh api --method PATCH "/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}" \
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

wait_for_run() {
  local run_id="$1"
  local label="$2"
  local document status conclusion head_sha
  for _ in $(seq 1 900); do
    document="$(run_document "$run_id")"
    head_sha="$(jq -r .headSha <<<"$document")"
    [[ "$head_sha" == "$SOURCE_SHA" ]] || {
      echo "::error::${label} run ${run_id} targets ${head_sha}, expected ${SOURCE_SHA}" >&2
      return 1
    }
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
  gh workflow run "$workflow" --repo "$GITHUB_REPOSITORY" --ref main "$@" >/dev/null
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

CURRENT_STEP="verifying-clean-source"
issue_update running "$CURRENT_STEP"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git fetch origin main
git cat-file -e "${SOURCE_SHA}^{commit}"
git merge-base --is-ancestor "$SOURCE_SHA" origin/main
if git remote get-url upstream >/dev/null 2>&1; then
  git remote set-url upstream https://github.com/openai/codex.git
else
  git remote add upstream https://github.com/openai/codex.git
fi
git fetch --no-tags upstream "refs/tags/${UPSTREAM_TAG}:refs/tags/${UPSTREAM_TAG}"
[[ "$(git rev-parse "${UPSTREAM_TAG}^{commit}")" == "$UPSTREAM_COMMIT" ]]
git merge-base --is-ancestor "$UPSTREAM_COMMIT" "$SOURCE_SHA"
[[ "$(git ls-remote upstream refs/heads/latest-alpha-cli | awk '{print $1}')" == "$UPSTREAM_COMMIT" ]]

source_version="$(
  git show "${SOURCE_SHA}:codex-rs/Cargo.toml" | awk '
    /^\[workspace\.package\]$/ { in_package=1; next }
    /^\[/ && in_package { exit }
    in_package && /^version[[:space:]]*=/ {
      value=$0
      sub(/^[^=]*=[[:space:]]*"/, "", value)
      sub(/".*$/, "", value)
      print value
      exit
    }
  '
)"
[[ "$source_version" == "$PACKAGE_VERSION" ]]

CURRENT_STEP="waiting-for-exact-source-gates"
issue_update running "$CURRENT_STEP"
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
git checkout -B main origin/main
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
append_patch_audit "termux: stage ${PACKAGE_VERSION} publication" tooling \
  "Records successful exact-source control-plane, ARM64, and Android validation evidence for publication."
append_patch_audit "termux: promote ${RELEASE_TAG}" tooling \
  "Promotes the byte-verified public release manifest after publication."
git add scripts/termux/release-publication.env scripts/termux/patch_audit.tsv
git commit -m "termux: stage ${PACKAGE_VERSION} publication"
PUBLICATION_SHA="$(git rev-parse HEAD)"
git push origin HEAD:main

CURRENT_STEP="waiting-for-release-publication"
RELEASE_RUN_ID="$(dispatch_and_find termux-release-request.yml "$PUBLICATION_SHA")"
issue_update running "$CURRENT_STEP"
for _ in $(seq 1 600); do
  document="$(run_document "$RELEASE_RUN_ID")"
  status="$(jq -r .status <<<"$document")"
  if [[ "$status" == "completed" ]]; then
    conclusion="$(jq -r '.conclusion // "missing"' <<<"$document")"
    [[ "$conclusion" == "success" ]] || { printf '%s\n' "$document" >&2; exit 1; }
    break
  fi
  sleep 10
done
[[ "$(jq -r .status <<<"$(run_document "$RELEASE_RUN_ID")")" == "completed" ]]
[[ "$(jq -r .conclusion <<<"$(run_document "$RELEASE_RUN_ID")")" == "success" ]]

CURRENT_STEP="verifying-live-release"
promoted=false
for _ in $(seq 1 120); do
  latest_tag="$(gh api "/repos/${GITHUB_REPOSITORY}/releases/latest" --jq .tag_name)"
  manifest_text="$(gh api "/repos/${GITHUB_REPOSITORY}/contents/scripts/termux/release-manifest.env?ref=main" --jq .content | tr -d '\n' | base64 --decode)"
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

CURRENT_STEP="waiting-for-final-direct-cleanup"
issue_update awaiting-final-cleanup "release-published:${RELEASE_TAG}"
cleaned=false
for _ in $(seq 1 180); do
  git fetch origin main
  git reset --hard origin/main
  if [[ ! -e .github/scripts/alpha12-resume.sh ]] \
    && ! grep -q 'alpha12-resume:' .github/workflows/blocking-ci.yml \
    && ! grep -q 'TEMP_RESUME_SCRIPT' .github/scripts/validate-termux-workflow-topology.py; then
    python3 .github/scripts/validate-termux-workflow-topology.py
    cargo metadata --manifest-path codex-rs/Cargo.toml --locked --format-version=1 >/dev/null
    [[ -z "$(git status --porcelain)" ]]
    FINAL_MAIN_SHA="$(git rev-parse HEAD)"
    cleaned=true
    break
  fi
  sleep 5
done
[[ "$cleaned" == "true" ]]

CURRENT_STEP="dispatching-post-promotion-checks"
POST_FORK_CI_RUN_ID="$(dispatch_and_find blocking-ci.yml "$FINAL_MAIN_SHA")"
POST_CONTROL_RUN_ID="$(dispatch_and_find termux-control-plane.yml "$FINAL_MAIN_SHA")"
CHANNEL_RUN_ID="$(dispatch_and_find termux-release-channel.yml "$FINAL_MAIN_SHA")"
GOVERNANCE_RUN_ID="$(dispatch_and_find termux-governance-audit.yml "$FINAL_MAIN_SHA")"
issue_update running "$CURRENT_STEP"

CURRENT_STEP="waiting-for-post-promotion-checks"
for pair in "$POST_FORK_CI_RUN_ID:post-fork-ci" "$POST_CONTROL_RUN_ID:post-control-plane" "$CHANNEL_RUN_ID:release-channel" "$GOVERNANCE_RUN_ID:governance-audit"; do
  run_id="${pair%%:*}"
  label="${pair#*:}"
  for _ in $(seq 1 600); do
    document="$(run_document "$run_id")"
    status="$(jq -r .status <<<"$document")"
    if [[ "$status" == "completed" ]]; then
      conclusion="$(jq -r '.conclusion // "missing"' <<<"$document")"
      [[ "$conclusion" == "success" ]] || { echo "::error::${label} run ${run_id} concluded ${conclusion}" >&2; exit 1; }
      break
    fi
    sleep 10
  done
  [[ "$(jq -r .status <<<"$(run_document "$run_id")")" == "completed" ]]
  [[ "$(jq -r .conclusion <<<"$(run_document "$run_id")")" == "success" ]]
done

CURRENT_STEP="cleaning-staging-branches"
for branch in alpha-0.150.0-alpha.8-staging "$STAGING_BRANCH"; do
  encoded="$(jq -rn --arg value "$branch" '$value|@uri')"
  if gh api "/repos/${GITHUB_REPOSITORY}/git/ref/heads/${encoded}" >/dev/null 2>&1; then
    gh api --method DELETE "/repos/${GITHUB_REPOSITORY}/git/refs/heads/${encoded}" >/dev/null
  fi
done
issue_update completed "published-and-post-verified"
gh issue close "$ISSUE_NUMBER" --repo "$GITHUB_REPOSITORY" \
  --comment "Codex ${PACKAGE_VERSION} was exact-source validated, published as GitHub Latest, cleaned, and post-verified." >/dev/null
