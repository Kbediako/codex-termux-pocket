#!/usr/bin/env bash
set -Eeuo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"

repo="$GITHUB_REPOSITORY"
run_url="https://github.com/${repo}/actions/runs/${GITHUB_RUN_ID}"
log_file="${RUNNER_TEMP}/validated-alpha-publication.log"

SOURCE_SHA="329147e2fab2ddf5f9e8e607efc2a3ba1f5f712c"
PACKAGE_VERSION="0.149.0-alpha.1"
RELEASE_TAG="termux-v2026.08.19-alpha.1-329147e2fa"
EXPECTED_CODEX_VERSION="codex-cli 329147e"
CONTROL_RUN_ID="32209449072"
ARTIFACT_RUN_ID="32209918341"
ANDROID_RUN_ID="32209449113"

exec > >(tee -a "$log_file") 2>&1

post_comment() {
  local body="$1"
  gh issue comment 44 --repo "$repo" --body "$body"
}

on_error() {
  local status=$?
  trap - ERR
  set +e
  excerpt="$(tail -n 180 "$log_file" 2>/dev/null || true)"
  post_comment "## Latest alpha publication failed

Workflow: ${run_url}

\`\`\`text
${excerpt}
\`\`\`

The previously promoted runtime remains the fallback unless this run explicitly recorded a completed release and manifest promotion before the failure."
  exit "$status"
}
trap on_error ERR

post_comment "Validated 0.149.0-alpha.1 publication started: ${run_url}"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git fetch --no-tags origin main
main_sha="$(git rev-parse origin/main)"
[[ "$main_sha" == "$GITHUB_SHA" ]] || {
  echo "main advanced to ${main_sha}; expected workflow source ${GITHUB_SHA}" >&2
  exit 1
}
git checkout -B main "$GITHUB_SHA"

cancel_active_runs() {
  local workflow="$1"
  local response run_id
  response="$(
    gh api "/repos/${repo}/actions/workflows/${workflow}/runs?branch=main&per_page=100" 2>/dev/null || true
  )"
  [[ -n "$response" ]] || return 0
  while IFS= read -r run_id; do
    [[ -n "$run_id" ]] || continue
    [[ "$run_id" == "$GITHUB_RUN_ID" ]] && continue
    echo "Cancelling stale ${workflow} run ${run_id}"
    gh api --method POST "/repos/${repo}/actions/runs/${run_id}/cancel" >/dev/null || true
  done < <(
    jq -r '.workflow_runs[]
      | select(.status == "queued" or .status == "pending" or .status == "in_progress" or .status == "waiting" or .status == "requested")
      | .id' <<<"$response"
  )
}

for stale_workflow in \
  publish-validated-alpha-149-once.yml \
  trigger-publish-validated-alpha-149-once.yml \
  finish-repository-cleanup-and-alpha-release-once.yml \
  trigger-finish-repository-cleanup-once.yml \
  update-latest-alpha-once.yml; do
  cancel_active_runs "$stale_workflow"
done

python3 - <<'PY'
from pathlib import Path

release_path = Path('.github/workflows/termux-release-request.yml')
text = release_path.read_text(encoding='utf-8')


def replace_or_verify(old: str, new: str, label: str) -> None:
    global text
    old_count = text.count(old)
    new_count = text.count(new)
    if old_count == 1:
        text = text.replace(old, new, 1)
    elif old_count == 0 and new_count == 1:
        return
    else:
        raise SystemExit(
            f'{label}: expected one old match or one existing new match; '
            f'found old={old_count}, new={new_count}'
        )


replace_or_verify(
    '      - "scripts/termux/release-request.env"\n'
    '      - ".github/workflows/termux-release-request.yml"\n',
    '      - "scripts/termux/release-request.env"\n',
    'release self-trigger',
)
replace_or_verify(
    '''          main_sha="$(
            gh api "/repos/${GITHUB_REPOSITORY}/git/ref/heads/main" --jq .object.sha
          )"
          [[ "$main_sha" == "$GITHUB_SHA" ]] || {
            echo "::error::main advanced to ${main_sha}; refusing to publish stale workflow head ${GITHUB_SHA}"
            exit 1
          }
''',
    '''          git fetch --no-tags origin main
          main_sha="$(git rev-parse origin/main)"
          git merge-base --is-ancestor "$GITHUB_SHA" "$main_sha" || {
            echo "::error::Validated source ${GITHUB_SHA} is not an ancestor of current main ${main_sha}"
            exit 1
          }
''',
    'main ancestry gate',
)
replace_or_verify(
    '              --latest=false \\\n',
    '              --latest \\\n',
    'Latest creation flag',
)
latest_gate = '''          latest_tag="$(
            gh api "/repos/${GITHUB_REPOSITORY}/releases/latest" --jq .tag_name
          )"
          [[ "$latest_tag" == "$RELEASE_TAG" ]] || {
            echo "::error::GitHub Latest resolved to ${latest_tag}, expected ${RELEASE_TAG}"
            exit 1
          }

'''
if latest_gate not in text:
    marker = '''          fi

      - name: Verify anonymous public release downloads
'''
    if text.count(marker) != 1:
        raise SystemExit('Latest verification gate: insertion marker not found exactly once')
    text = text.replace(
        marker,
        '          fi\n\n' + latest_gate +
        '      - name: Verify anonymous public release downloads\n',
        1,
    )
release_path.write_text(text, encoding='utf-8')

channel_path = Path('.github/workflows/termux-release-channel.yml')
channel_path.write_text('''name: termux-release-channel
run-name: Verify validated Termux release channel

# The publisher marks a validated release as Latest in the release-creation
# transaction. This workflow never mutates an immutable published release; it
# verifies that the promoted manifest and GitHub Latest endpoint agree.
on:
  workflow_run:
    workflows:
      - termux-release-request
    types:
      - completed
  workflow_dispatch:

permissions:
  actions: write
  contents: read

concurrency:
  group: termux-release-channel
  cancel-in-progress: true

jobs:
  verify-latest:
    if: ${{ github.event_name != 'workflow_run' || github.event.workflow_run.conclusion == 'success' }}
    name: Verify promoted runtime is Latest
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - name: Checkout promoted main
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          ref: main
          persist-credentials: false

      - name: Verify the promoted release is Latest
        env:
          GH_TOKEN: ${{ github.token }}
        shell: bash
        run: |
          set -euo pipefail
          manifest="scripts/termux/release-manifest.env"

          read_value() {
            local key="$1"
            local value
            value="$(sed -n "s/^${key}=//p" "$manifest")"
            if [[ -z "$value" || "$(grep -c "^${key}=" "$manifest")" -ne 1 ]]; then
              echo "::error file=${manifest}::Expected exactly one non-empty ${key}= entry"
              exit 1
            fi
            printf '%s' "$value"
          }

          repository="$(read_value repository)"
          release_tag="$(read_value release_tag)"
          head_sha="$(read_value head_sha)"
          [[ "$repository" == "$GITHUB_REPOSITORY" ]]
          [[ "$release_tag" =~ ^termux-v[0-9A-Za-z._-]+$ ]]
          [[ "$head_sha" =~ ^[0-9a-f]{40}$ ]]

          release_json="$(
            gh api "/repos/${GITHUB_REPOSITORY}/releases/tags/${release_tag}"
          )"
          release_target="$(jq -r .target_commitish <<<"$release_json")"
          draft="$(jq -r .draft <<<"$release_json")"
          [[ "$release_target" == "$head_sha" ]]
          [[ "$draft" == "false" ]]

          latest_tag="$(
            gh api "/repos/${GITHUB_REPOSITORY}/releases/latest" --jq .tag_name
          )"
          [[ "$latest_tag" == "$release_tag" ]] || {
            echo "::error::GitHub Latest resolved to ${latest_tag}, expected ${release_tag}"
            exit 1
          }

          {
            echo "### Termux release channel"
            echo
            echo "- Latest release: \`${release_tag}\`"
            echo "- Runtime commit: \`${head_sha}\`"
          } >> "$GITHUB_STEP_SUMMARY"

      - name: Run post-promotion governance audit
        env:
          GH_TOKEN: ${{ github.token }}
        shell: bash
        run: |
          set -euo pipefail
          gh workflow run termux-governance-audit.yml \
            --repo "$GITHUB_REPOSITORY" \
            --ref main
''', encoding='utf-8')
PY

rm -f \
  .github/workflows/finish-repository-cleanup-and-alpha-release-once.yml \
  .github/workflows/trigger-finish-repository-cleanup-once.yml \
  .github/workflows/update-latest-alpha-once.yml \
  .github/workflows/publish-validated-alpha-149-once.yml \
  .github/workflows/trigger-publish-validated-alpha-149-once.yml \
  .github/repair-release-go

ruby -e 'require "yaml"; YAML.load_file(".github/workflows/termux-release-request.yml", aliases: true); YAML.load_file(".github/workflows/termux-release-channel.yml", aliases: true)'
git diff --check
git add -A
if ! git diff --cached --quiet; then
  git commit -m "fix(termux): publish validated alphas as Latest"
  git push origin HEAD:main
fi

verify_run() {
  local run_id="$1"
  local label="$2"
  local run_json
  run_json="$(gh api "/repos/${repo}/actions/runs/${run_id}")"
  [[ "$(jq -r .head_sha <<<"$run_json")" == "$SOURCE_SHA" ]] || {
    echo "${label} run ${run_id} validated a different source" >&2
    exit 1
  }
  [[ "$(jq -r .status <<<"$run_json")" == "completed" ]]
  [[ "$(jq -r .conclusion <<<"$run_json")" == "success" ]] || {
    echo "${label} run ${run_id} was not successful" >&2
    exit 1
  }
}

verify_run "$CONTROL_RUN_ID" "Termux control-plane"
verify_run "$ARTIFACT_RUN_ID" "ARM64 artifact"
verify_run "$ANDROID_RUN_ID" "Android/Termux"

rm -rf dist
mkdir -p dist
gh run download "$ARTIFACT_RUN_ID" \
  --repo "$repo" \
  --name codex-termux-aarch64-unknown-linux-musl \
  --dir dist

cd dist
for file in \
  codex-termux-aarch64-unknown-linux-musl.tar.gz \
  metadata.env \
  SHA256SUMS \
  codex-termux-sbom.spdx.json; do
  [[ -f "$file" ]] || { echo "Missing ${file}" >&2; exit 1; }
done
sha256sum --check --strict SHA256SUMS
python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' codex-termux-sbom.spdx.json

metadata_value() {
  local key="$1"
  local value
  value="$(sed -n "s/^${key}=//p" metadata.env)"
  [[ -n "$value" && "$(grep -c "^${key}=" metadata.env)" -eq 1 ]]
  printf '%s' "$value"
}

head_sha="$(metadata_value head_sha)"
codex_version="$(metadata_value codex_version)"
target="$(metadata_value target)"
archive_size_bytes="$(metadata_value archive_size_bytes)"
runtime_size_bytes="$(metadata_value runtime_size_bytes)"
[[ "$head_sha" == "$SOURCE_SHA" ]]
[[ "$codex_version" == "$EXPECTED_CODEX_VERSION" ]]
[[ "$target" == "aarch64-unknown-linux-musl" ]]
[[ "$archive_size_bytes" == "$(stat -c '%s' codex-termux-aarch64-unknown-linux-musl.tar.gz)" ]]

archive_sha256="$(sha256sum codex-termux-aarch64-unknown-linux-musl.tar.gz | awk '{print $1}')"
printf '%s\n' \
  'format_version=2' \
  "repository=${repo}" \
  "release_tag=${RELEASE_TAG}" \
  "head_sha=${SOURCE_SHA}" \
  "codex_version=${EXPECTED_CODEX_VERSION}" \
  "archive_sha256=${archive_sha256}" \
  "archive_size_bytes=${archive_size_bytes}" \
  "runtime_size_bytes=${runtime_size_bytes}" \
  > release-manifest.env

release_files=(
  codex-termux-aarch64-unknown-linux-musl.tar.gz
  metadata.env
  SHA256SUMS
  codex-termux-sbom.spdx.json
  release-manifest.env
)
if gh release view "$RELEASE_TAG" --repo "$repo" >/dev/null 2>&1; then
  existing_dir="$(mktemp -d)"
  gh release download "$RELEASE_TAG" --repo "$repo" --dir "$existing_dir"
  for file in "${release_files[@]}"; do
    cmp --silent "$file" "$existing_dir/$file" || {
      echo "Existing immutable release asset differs: ${file}" >&2
      exit 1
    }
  done
else
  gh release create "$RELEASE_TAG" \
    --repo "$repo" \
    --target "$SOURCE_SHA" \
    --title "Codex Termux ${PACKAGE_VERSION} (${EXPECTED_CODEX_VERSION})" \
    --notes "Verified complete Termux runtime for OpenAI Codex CLI ${PACKAGE_VERSION}. Exact-source ARM64 artifact, Termux control-plane, and official Android/Termux emulator validation passed before publication." \
    --latest \
    "${release_files[@]}"
fi

latest_tag="$(gh api "/repos/${repo}/releases/latest" --jq .tag_name)"
[[ "$latest_tag" == "$RELEASE_TAG" ]] || {
  echo "GitHub Latest resolved to ${latest_tag}, expected ${RELEASE_TAG}" >&2
  exit 1
}

public_dir="$(mktemp -d)"
base="https://github.com/${repo}/releases/download/${RELEASE_TAG}"
for file in "${release_files[@]}"; do
  curl --fail --location --silent --show-error --retry 8 \
    "${base}/${file}" -o "${public_dir}/${file}"
  cmp --silent "$file" "${public_dir}/${file}"
done
(cd "$public_dir" && sha256sum --check --strict SHA256SUMS)

cd "$GITHUB_WORKSPACE"
git pull --ff-only origin main
cp dist/release-manifest.env scripts/termux/release-manifest.env
git add scripts/termux/release-manifest.env
if ! git diff --cached --quiet; then
  git commit -m "termux: promote ${RELEASE_TAG}"
  git push origin HEAD:main
fi
promotion_sha="$(git rev-parse HEAD)"

for workflow in termux-control-plane.yml termux-release-channel.yml termux-governance-audit.yml; do
  gh workflow run "$workflow" --repo "$repo" --ref main
  echo "Dispatched ${workflow} for ${promotion_sha}"
done

wait_for_workflow() {
  local workflow="$1"
  local label="$2"
  local run_id="" status="" conclusion="" state=""
  for _ in $(seq 1 160); do
    state="$(
      gh api "/repos/${repo}/actions/workflows/${workflow}/runs?branch=main&per_page=100" \
        --jq ".workflow_runs
          | map(select(.head_sha == \"${promotion_sha}\" and .event == \"workflow_dispatch\"))
          | first // {}
          | [(.id // \"\"), (.status // \"\"), (.conclusion // \"\")]
          | @tsv"
    )"
    IFS=$'\t' read -r run_id status conclusion <<<"$state"
    if [[ "$status" == "completed" ]]; then
      [[ "$conclusion" == "success" ]] || {
        echo "${label} run ${run_id} concluded ${conclusion}" >&2
        exit 1
      }
      printf '%s' "$run_id"
      return 0
    fi
    sleep 15
  done
  echo "${label} did not complete successfully" >&2
  return 1
}

post_control_run="$(wait_for_workflow termux-control-plane.yml 'Termux control-plane')"
release_channel_run="$(wait_for_workflow termux-release-channel.yml 'Termux release channel')"
governance_run="$(wait_for_workflow termux-governance-audit.yml 'Termux governance audit')"

manifest_tag="$(sed -n 's/^release_tag=//p' scripts/termux/release-manifest.env)"
latest_tag="$(gh api "/repos/${repo}/releases/latest" --jq .tag_name)"
[[ "$manifest_tag" == "$RELEASE_TAG" && "$latest_tag" == "$RELEASE_TAG" ]]

mapfile -t open_prs < <(gh pr list --repo "$repo" --state open --limit 100 --json number --jq '.[].number')
(( ${#open_prs[@]} == 0 )) || {
  printf 'Open PRs remain: %s\n' "${open_prs[*]}" >&2
  exit 1
}
mapfile -t branches < <(gh api --paginate "/repos/${repo}/branches?per_page=100" --jq '.[].name')
[[ "${#branches[@]}" -eq 1 && "${branches[0]}" == "main" ]] || {
  printf 'Unexpected branches remain:\n' >&2
  printf '  %s\n' "${branches[@]}" >&2
  exit 1
}

git pull --ff-only origin main
rm -f \
  .github/repair-release-trigger \
  .github/scripts/repair-release-and-clean-repo-once.sh \
  .github/workflows/repair-release-and-clean-repo-once.yml \
  .github/workflows/finish-repository-cleanup-and-alpha-release-once.yml \
  .github/workflows/trigger-finish-repository-cleanup-once.yml \
  .github/workflows/update-latest-alpha-once.yml \
  .github/workflows/publish-validated-alpha-149-once.yml \
  .github/workflows/trigger-publish-validated-alpha-149-once.yml \
  .github/repair-release-go

git add -A
if ! git diff --cached --quiet; then
  git commit -m "chore: remove one-time release repair workflows"
  git push origin HEAD:main
fi

post_comment "## Latest alpha publication completed

- Release: [${RELEASE_TAG}](https://github.com/${repo}/releases/tag/${RELEASE_TAG})
- Package: \`${PACKAGE_VERSION}\`
- Runtime source: \`${SOURCE_SHA}\`
- Binary: \`${EXPECTED_CODEX_VERSION}\`
- Archive SHA-256: \`${archive_sha256}\`
- Post-promotion control-plane: [${post_control_run}](https://github.com/${repo}/actions/runs/${post_control_run})
- Release-channel verification: [${release_channel_run}](https://github.com/${repo}/actions/runs/${release_channel_run})
- Governance audit: [${governance_run}](https://github.com/${repo}/actions/runs/${governance_run})

The promoted manifest and GitHub Latest endpoint both resolve to this immutable 0.149.0-alpha.1 release. There are no open pull requests and only \`main\` remains."

trap - ERR
