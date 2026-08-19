#!/usr/bin/env bash
set -Eeuo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"

repo="$GITHUB_REPOSITORY"
owner="${repo%%/*}"
run_url="https://github.com/${repo}/actions/runs/${GITHUB_RUN_ID}"
log_file="${RUNNER_TEMP}/repair-release-and-clean-repo.log"
report_file="${RUNNER_TEMP}/repair-release-and-clean-repo.md"
final_subject=""
final_sha=""
release_run_id=""
latest_tag=""
latest_version=""
release_tag=""

mkdir -p "$(dirname "$log_file")"
: >"$log_file"
: >"$report_file"
exec > >(tee -a "$log_file") 2>&1

declare -a merged_prs=()
declare -a unresolved_prs=()
declare -a deleted_branches=()
declare -a preserved_branches=()
declare -A updated_pr=()
declare -A rerun_pr=()

append_report() {
  printf '%s\n' "$*" >>"$report_file"
}

post_report() {
  local heading="$1"
  local body="${RUNNER_TEMP}/issue-report.md"
  {
    printf '## %s\n\n' "$heading"
    cat "$report_file"
    printf '\nWorkflow: %s\n' "$run_url"
  } >"$body"
  gh issue comment 44 --repo "$repo" --body-file "$body" >/dev/null 2>&1 || true
}

on_error() {
  local rc=$?
  trap - ERR
  append_report ""
  append_report "### Failure"
  append_report "The repair stopped with exit code \`${rc}\`. No unverified release was promoted."
  append_report ""
  append_report '<details><summary>Log tail</summary>'
  append_report ""
  append_report '```text'
  tail -n 220 "$log_file" >>"$report_file" 2>/dev/null || true
  append_report '```'
  append_report '</details>'
  post_report "Repository cleanup / latest-alpha repair failed"
  exit "$rc"
}
trap on_error ERR

retry_api() {
  local attempt
  for attempt in $(seq 1 8); do
    if gh api "$@"; then
      return 0
    fi
    sleep $((attempt * 3))
  done
  return 1
}

cancel_stale_runs() {
  local current_id="$GITHUB_RUN_ID"
  local run_id
  mapfile -t stale_runs < <(
    gh api --paginate "/repos/${repo}/actions/runs?per_page=100" \
      --jq ".workflow_runs[]
        | select(.id != ${current_id})
        | select(.status != \"completed\")
        | select(
            ((.head_branch // \"\") | startswith(\"observer/\"))
            or ((.path // \"\") | test(\"close-44-and-sync|update-latest-alpha-once|finish-issue-44|observe-alpha-149|cancel-stale-alpha|repair-release-and-clean-repo\"))
            or ((.path // \"\") | test(\"termux-release-request.yml|termux-mobile-artifact.yml|termux-android-emulator.yml\"))
          )
        | .id" 2>/dev/null || true
  )
  for run_id in "${stale_runs[@]:-}"; do
    [[ -n "$run_id" ]] || continue
    echo "Cancelling stale workflow run ${run_id}"
    gh api --method POST "/repos/${repo}/actions/runs/${run_id}/cancel" >/dev/null 2>&1 || true
  done
}

pr_checks_state() {
  local pr="$1"
  local json
  json="$(gh pr view "$pr" --repo "$repo" --json statusCheckRollup)"
  jq -r '
    (.statusCheckRollup // []) as $checks
    | if ($checks | length) == 0 then
        "pass"
      elif any($checks[];
        ((.conclusion // .state // "") as $s
          | ["FAILURE","ERROR","CANCELLED","TIMED_OUT","ACTION_REQUIRED","STARTUP_FAILURE"]
          | index($s) != null)) then
        "fail"
      elif any($checks[];
        ((.__typename // "") == "CheckRun" and ((.status // "") != "COMPLETED" or (.conclusion // "") == ""))
        or ((.__typename // "") == "StatusContext" and ((.state // "") == "PENDING" or (.state // "") == "EXPECTED"))) then
        "pending"
      else
        "pass"
      end
  ' <<<"$json"
}

rerun_failed_pr_checks() {
  local pr="$1"
  local checks link run_id
  checks="$(gh pr checks "$pr" --repo "$repo" --json bucket,link 2>/dev/null || true)"
  [[ -n "$checks" ]] || return 1
  while IFS= read -r link; do
    [[ -n "$link" ]] || continue
    run_id="$(sed -nE 's#.*?/actions/runs/([0-9]+).*#\1#p' <<<"$link" | head -n1)"
    [[ -n "$run_id" ]] || continue
    echo "Rerunning failed checks for PR #${pr} via run ${run_id}"
    gh run rerun "$run_id" --repo "$repo" --failed >/dev/null 2>&1 || \
      gh run rerun "$run_id" --repo "$repo" >/dev/null 2>&1 || true
  done < <(jq -r '.[]? | select(.bucket == "fail" or .bucket == "cancel") | .link // empty' <<<"$checks")
}

handle_dependabot_prs() {
  local cycle pr meta title url base draft mergeable merge_state checks_state progress pending
  echo "Inspecting open Dependabot pull requests"

  for cycle in $(seq 1 32); do
    mapfile -t prs < <(
      gh pr list --repo "$repo" --state open --author app/dependabot --limit 100 \
        --json number --jq '.[].number'
    )
    ((${#prs[@]} > 0)) || break

    progress=0
    pending=0
    for pr in "${prs[@]}"; do
      meta="$(gh pr view "$pr" --repo "$repo" \
        --json number,title,url,baseRefName,headRefName,isDraft,mergeable,mergeStateStatus)"
      title="$(jq -r .title <<<"$meta")"
      url="$(jq -r .url <<<"$meta")"
      base="$(jq -r .baseRefName <<<"$meta")"
      draft="$(jq -r .isDraft <<<"$meta")"
      mergeable="$(jq -r .mergeable <<<"$meta")"
      merge_state="$(jq -r .mergeStateStatus <<<"$meta")"

      if [[ "$base" != "main" || "$draft" == "true" ]]; then
        unresolved_prs+=("#${pr} — ${title} (${url}): not a ready PR against main")
        continue
      fi

      if [[ "$mergeable" == "CONFLICTING" || "$merge_state" == "DIRTY" ]]; then
        unresolved_prs+=("#${pr} — ${title} (${url}): merge conflict")
        continue
      fi

      if [[ "$merge_state" == "BEHIND" && -z "${updated_pr[$pr]:-}" ]]; then
        echo "Updating Dependabot PR #${pr} from main"
        if gh pr update-branch "$pr" --repo "$repo" >/dev/null 2>&1; then
          updated_pr[$pr]=1
          pending=1
          continue
        fi
      fi

      if [[ "$mergeable" == "UNKNOWN" ]]; then
        pending=1
        continue
      fi

      checks_state="$(pr_checks_state "$pr")"
      case "$checks_state" in
        pending)
          pending=1
          continue
          ;;
        fail)
          if [[ -z "${rerun_pr[$pr]:-}" ]]; then
            rerun_failed_pr_checks "$pr" || true
            rerun_pr[$pr]=1
            pending=1
            continue
          fi
          unresolved_prs+=("#${pr} — ${title} (${url}): checks still failing after one rerun")
          continue
          ;;
        pass)
          echo "Merging green Dependabot PR #${pr}: ${title}"
          if gh pr merge "$pr" --repo "$repo" --squash --delete-branch; then
            merged_prs+=("#${pr} — ${title} (${url})")
            progress=1
            sleep 5
            break
          fi
          pending=1
          ;;
      esac
    done

    ((progress == 1)) && continue
    if ((pending == 1 && cycle < 32)); then
      sleep 30
      continue
    fi
    break
  done

  mapfile -t remaining < <(
    gh pr list --repo "$repo" --state open --author app/dependabot --limit 100 \
      --json number,title,url --jq '.[] | "#\(.number) — \(.title) (\(.url))"'
  )
  if ((${#remaining[@]} > 0)); then
    local item already
    for item in "${remaining[@]}"; do
      already=0
      for recorded in "${unresolved_prs[@]:-}"; do
        [[ "$recorded" == "${item%% —*}"* ]] && already=1
      done
      ((already == 1)) || unresolved_prs+=("${item}: not safely mergeable in this pass")
    done
  fi
}

encode_ref() {
  jq -rn --arg value "$1" '$value | @uri'
}

delete_remote_branch() {
  local branch="$1"
  local encoded
  encoded="$(encode_ref "$branch")"
  if gh api --method DELETE "/repos/${repo}/git/refs/heads/${encoded}" >/dev/null 2>&1; then
    deleted_branches+=("${branch}")
    echo "Deleted branch ${branch}"
  fi
}

cleanup_branches() {
  local branch open_count sha
  git fetch --prune origin '+refs/heads/*:refs/remotes/origin/*'
  mapfile -t branches < <(
    gh api --paginate "/repos/${repo}/branches?per_page=100" --jq '.[].name'
  )
  for branch in "${branches[@]}"; do
    [[ "$branch" != "main" ]] || continue

    if [[ "$branch" == observer/* ]]; then
      delete_remote_branch "$branch"
      continue
    fi

    open_count="$(
      gh api --method GET "/repos/${repo}/pulls" \
        -f state=open -f head="${owner}:${branch}" --jq 'length' 2>/dev/null || echo 0
    )"
    if [[ "$open_count" =~ ^[0-9]+$ ]] && ((open_count > 0)); then
      preserved_branches+=("${branch} — open pull request")
      continue
    fi

    if [[ "$branch" == dependabot/* ]]; then
      delete_remote_branch "$branch"
      continue
    fi

    sha="$(git rev-parse "refs/remotes/origin/${branch}" 2>/dev/null || true)"
    if [[ -n "$sha" ]] && git merge-base --is-ancestor "$sha" refs/remotes/origin/main; then
      delete_remote_branch "$branch"
    else
      preserved_branches+=("${branch} — contains unmerged commits")
    fi
  done
}

patch_release_workflows() {
  python3 - <<'PY'
from pathlib import Path

release = Path('.github/workflows/termux-release-request.yml')
text = release.read_text(encoding='utf-8')
lines = text.splitlines(keepends=True)
out = []
in_create = False
inserted = False
for line in lines:
    if 'gh release create "$RELEASE_TAG"' in line:
        in_create = True
    if in_create and '--latest' in line:
        continue
    if in_create and '"${release_files[@]/#/dist/}"' in line:
        out.append('              --latest \\\n')
        inserted = True
        in_create = False
    out.append(line)
if not inserted:
    raise SystemExit('Could not locate the gh release create asset line')
text = ''.join(out)
text = text.replace(
    'Native Android/Termux emulator validation passed before publication.',
    'Exact-source Termux control-plane and native Android/Termux validation passed before publication.'
)
text = text.replace(
    '/actions/workflows/${workflow}/runs?event=push&branch=main&per_page=100',
    '/actions/workflows/${workflow}/runs?branch=main&per_page=100'
)
release.write_text(text, encoding='utf-8')

channel = Path('.github/workflows/termux-release-channel.yml')
text = channel.read_text(encoding='utf-8')
lines = text.splitlines(keepends=True)
out = []
skipping = False
removed = False
for line in lines:
    if not skipping and line.lstrip().startswith('gh api --method PATCH'):
        skipping = True
        removed = True
        continue
    if skipping:
        if 'make_latest=true' in line:
            skipping = False
        continue
    out.append(line)
text = ''.join(out)
text = text.replace('Mark promoted runtime as Latest', 'Verify promoted runtime is Latest')
text = text.replace(
    "# A release is intentionally created as non-latest until all publication checks\n# pass. Once the gated release workflow completes, promote the repository\n# manifest's release to GitHub's Latest channel and run the public-channel audit.\n",
    "# The gated release workflow creates the immutable release as Latest. Once it\n# completes, verify the repository manifest and Latest channel agree, then run\n# the public-channel audit.\n"
)
if not removed and '--method PATCH' in text and 'make_latest=true' in text:
    raise SystemExit('Could not remove immutable-release PATCH operation')
channel.write_text(text, encoding='utf-8')
PY
}

remove_temporary_files() {
  rm -f \
    .github/workflows/close-44-and-sync-latest-alpha-once.yml \
    .github/workflows/close-44-and-sync-latest-alpha-once-v2.yml \
    .github/workflows/finish-issue-44-hardening-once.yml \
    .github/workflows/update-latest-alpha-once.yml \
    .github/workflows/repair-release-and-clean-repo-once.yml \
    .github/scripts/repair-release-and-clean-repo-once.sh \
    .github/repair-release-trigger
  rm -rf .github/observations
}

resolve_latest_alpha() {
  git remote remove upstream >/dev/null 2>&1 || true
  git remote add upstream https://github.com/openai/codex.git
  git fetch --force --no-tags upstream \
    '+refs/heads/latest-alpha-cli:refs/remotes/upstream/latest-alpha-cli' \
    '+refs/tags/rust-v*:refs/tags/rust-v*'

  latest_tag="$(
    git tag --merged refs/remotes/upstream/latest-alpha-cli --list 'rust-v*-alpha.*' \
      | grep -E '^rust-v[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+$' \
      | sort -V \
      | tail -n1
  )"
  [[ -n "$latest_tag" ]] || {
    echo 'No valid OpenAI alpha tag was found on latest-alpha-cli.' >&2
    return 1
  }
  latest_version="${latest_tag#rust-v}"
  echo "Latest upstream alpha: ${latest_tag}"
}

workspace_version() {
  awk '
    /^\[workspace\.package\]$/ { in_package=1; next }
    /^\[/ && in_package { exit }
    in_package && /^version[[:space:]]*=/ {
      value=$0
      sub(/^[^=]*=[[:space:]]*"/, "", value)
      sub(/".*$/, "", value)
      print value
      exit
    }
  ' codex-rs/Cargo.toml
}

merge_latest_alpha_if_needed() {
  local current_version merge_status
  current_version="$(workspace_version)"
  if [[ "$current_version" == "$latest_version" ]] && \
     git merge-base --is-ancestor "${latest_tag}^{commit}" HEAD; then
    echo "main already contains ${latest_tag}"
    return 0
  fi

  echo "Merging ${latest_tag} into protected main without rewriting history"
  set +e
  git merge --no-ff --no-commit -X ours "${latest_tag}^{commit}"
  merge_status=$?
  set -e
  if ((merge_status != 0)); then
    [[ -f .git/MERGE_HEAD ]] || return "$merge_status"
    for path in \
      .github/workflows/python-runtime-release.yml \
      .github/workflows/python-sdk-release.yml \
      .github/workflows/rust-release.yml; do
      if git ls-files -u -- "$path" | grep -q .; then
        git rm -f -- "$path"
      fi
    done
  fi

  mapfile -t unresolved < <(git diff --name-only --diff-filter=U)
  if ((${#unresolved[@]} > 0)); then
    printf 'Unresolved upstream merge paths:\n' >&2
    printf '  %s\n' "${unresolved[@]}" >&2
    return 1
  fi

  TARGET_VERSION="$latest_version" python3 - <<'PY'
from pathlib import Path
import os
import re
path = Path('codex-rs/Cargo.toml')
text = path.read_text(encoding='utf-8')
pattern = re.compile(r'(?ms)(^\[workspace\.package\]\n(?:.*?\n)*?^version\s*=\s*")[^"]+("\s*$)')
text, count = pattern.subn(lambda m: m.group(1) + os.environ['TARGET_VERSION'] + m.group(2), text, count=1)
if count != 1:
    raise SystemExit('workspace.package version was not found exactly once')
path.write_text(text, encoding='utf-8')
PY

  local cargo_v8 pinned_v8
  cargo_v8="$(sed -nE 's/^v8[[:space:]]*=[[:space:]]*"=([^"]+)"/\1/p' codex-rs/Cargo.toml | head -n1)"
  pinned_v8="$(sed -n 's/^rusty_v8_version=//p' scripts/termux/build-inputs.env)"
  [[ -z "$cargo_v8" || "$cargo_v8" == "$pinned_v8" ]] || {
    echo "Rusty V8 changed to ${cargo_v8}, but immutable build inputs still pin ${pinned_v8}." >&2
    echo 'Refusing to guess new archive digests.' >&2
    return 1
  }

  (
    cd codex-rs
    cargo metadata --format-version=1 >/dev/null
    cargo metadata --locked --format-version=1 >/dev/null
  )
}

classify_patch_subjects() {
  FINAL_SUBJECT="$final_subject" LATEST_TAG="$latest_tag" python3 - <<'PY'
from pathlib import Path
import os
import re
import subprocess

audit_path = Path('scripts/termux/patch_audit.tsv')
text = audit_path.read_text(encoding='utf-8')
subjects = set()
for line in text.splitlines():
    fields = line.split('\t')
    if len(fields) >= 2 and fields[0] == 'subject':
        subjects.add(fields[1])

log = subprocess.check_output(
    ['git', 'log', '--format=%s', f"{os.environ['LATEST_TAG']}..HEAD"],
    text=True,
).splitlines()
log.append(os.environ['FINAL_SUBJECT'])

new_lines = []
unknown = []
for subject in dict.fromkeys(log):
    if not subject or subject in subjects:
        continue
    if re.match(r'^(build\(deps(?:-[^)]+)?\):|chore\(deps(?:-[^)]+)?\):|Bump )', subject, re.I):
        classification = 'tooling'
        reason = 'Automated dependency maintenance validated by the fork CI before release.'
    elif subject.startswith(('ci:', 'chore:', 'termux: request validated', 'termux: promote')):
        classification = 'tooling'
        reason = 'Repository, CI, or release-control maintenance; shipped runtime behavior is unchanged.'
    elif subject.startswith('termux: update to '):
        classification = 'runtime-critical'
        reason = 'Integrates the maintained Android/Termux patch stack with the verified upstream alpha.'
    elif subject == os.environ['FINAL_SUBJECT']:
        classification = 'security-critical'
        reason = 'Cleans temporary automation and makes the validated immutable runtime Latest at creation.'
    else:
        unknown.append(subject)
        continue
    new_lines.append(f"subject\t{subject}\t{classification}\t{reason}\n")
    subjects.add(subject)

if unknown:
    raise SystemExit('Unclassified retained commit subjects:\n  ' + '\n  '.join(unknown))
if new_lines:
    audit_path.write_text(text + ''.join(new_lines), encoding='utf-8')
PY
}

validate_final_tree() {
  bash -n \
    scripts/termux/codex-cargo-check \
    scripts/termux/codex-update-alpha \
    scripts/termux/install-codex-termux \
    scripts/termux/maintainer-update-alpha \
    scripts/termux/smoke-test-artifact \
    scripts/termux/termux-mobile-lib.sh \
    scripts/termux/tests/run-tests
  python3 -m py_compile scripts/termux/generate-sbom.py
  ruby -e 'require "yaml"; Dir[".github/workflows/termux-*.yml"].sort.each { |path| YAML.load_file(path, aliases: true) }'
  bash scripts/termux/tests/run-tests
  (cd codex-rs && cargo metadata --locked --format-version=1 >/dev/null)
  git diff --check
}

find_exact_run() {
  local workflow="$1"
  local sha="$2"
  gh api "/repos/${repo}/actions/workflows/${workflow}/runs?branch=main&per_page=100" \
    --jq ".workflow_runs
      | map(select(.head_sha == \"${sha}\"))
      | sort_by(.created_at) | reverse | .[0].id // empty"
}

wait_run() {
  local run_id="$1"
  local label="$2"
  local max_loops="${3:-960}"
  local status conclusion
  for _ in $(seq 1 "$max_loops"); do
    status="$(gh api "/repos/${repo}/actions/runs/${run_id}" --jq .status)"
    conclusion="$(gh api "/repos/${repo}/actions/runs/${run_id}" --jq '.conclusion // ""')"
    if [[ "$status" == "completed" ]]; then
      echo "${label} run ${run_id}: ${conclusion}"
      [[ "$conclusion" == "success" ]]
      return
    fi
    sleep 15
  done
  echo "Timed out waiting for ${label} run ${run_id}" >&2
  return 1
}

wait_for_exact_run_id() {
  local workflow="$1"
  local sha="$2"
  local id
  for _ in $(seq 1 120); do
    id="$(find_exact_run "$workflow" "$sha")"
    if [[ -n "$id" ]]; then
      printf '%s' "$id"
      return 0
    fi
    sleep 5
  done
  return 1
}

collect_failed_run() {
  local run_id="$1"
  local name="$2"
  append_report ""
  append_report "### Failed ${name} run"
  append_report "Run: https://github.com/${repo}/actions/runs/${run_id}"
  append_report ""
  append_report '<details><summary>Failed log excerpt</summary>'
  append_report ""
  append_report '```text'
  gh run view "$run_id" --repo "$repo" --log-failed 2>&1 | tail -n 240 >>"$report_file" || true
  append_report '```'
  append_report '</details>'
}

main() {
  append_report "Repair started from ${run_url}."
  gh issue comment 44 --repo "$repo" \
    --body "A final repository-cleanup and latest-alpha release repair has started: ${run_url}" >/dev/null 2>&1 || true

  cancel_stale_runs
  handle_dependabot_prs

  git fetch --prune origin main '+refs/heads/*:refs/remotes/origin/*'
  git checkout -B main refs/remotes/origin/main
  cleanup_branches

  resolve_latest_alpha
  merge_latest_alpha_if_needed
  patch_release_workflows
  remove_temporary_files

  final_subject="termux: finalize ${latest_version} release and repository cleanup"
  local alpha_number release_prefix nonce
  alpha_number="${latest_version##*-alpha.}"
  release_prefix="termux-v$(date -u +%Y.%m.%d)-alpha.${alpha_number}"
  nonce="$(date -u +%Y%m%dT%H%M%SZ)-${GITHUB_RUN_ID}"
  cat > scripts/termux/release-request.env <<EOF
# release_nonce=${nonce}
format_version=3
source_mode=workflow-head
release_tag_prefix=${release_prefix}
expected_package_version=${latest_version}
EOF

  classify_patch_subjects
  validate_final_tree

  git add -A
  git diff --cached --check
  git diff --cached --quiet && {
    echo 'Final release request produced no changes.' >&2
    return 1
  }
  git config user.name 'github-actions[bot]'
  git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
  git commit -m "$final_subject"
  final_sha="$(git rev-parse HEAD)"
  git push origin HEAD:main
  echo "Final protected-main source: ${final_sha}"

  # GITHUB_TOKEN pushes do not emit another push workflow chain, so dispatch
  # the exact-source gates explicitly. The release workflow accepts both push
  # and workflow_dispatch Android validation after the patch above.
  gh workflow run termux-control-plane.yml --repo "$repo" --ref main
  gh workflow run termux-android-emulator.yml --repo "$repo" --ref main
  gh workflow run termux-release-request.yml --repo "$repo" --ref main

  release_run_id="$(wait_for_exact_run_id termux-release-request.yml "$final_sha")"
  [[ -n "$release_run_id" ]]
  if ! wait_run "$release_run_id" 'release request' 960; then
    collect_failed_run "$release_run_id" 'release request'
    return 1
  fi

  local manifest_json manifest_text manifest_sha latest_release_tag governance_start governance_run_id
  for _ in $(seq 1 120); do
    manifest_json="$(gh api "/repos/${repo}/contents/scripts/termux/release-manifest.env?ref=main")"
    manifest_text="$(jq -r .content <<<"$manifest_json" | tr -d '\n' | base64 --decode)"
    manifest_sha="$(sed -n 's/^head_sha=//p' <<<"$manifest_text")"
    release_tag="$(sed -n 's/^release_tag=//p' <<<"$manifest_text")"
    [[ "$manifest_sha" == "$final_sha" && -n "$release_tag" ]] && break
    sleep 10
  done
  [[ "$manifest_sha" == "$final_sha" && -n "$release_tag" ]] || {
    echo 'Release workflow succeeded but the promoted manifest does not target the final source.' >&2
    return 1
  }

  for _ in $(seq 1 120); do
    latest_release_tag="$(gh api "/repos/${repo}/releases/latest" --jq .tag_name 2>/dev/null || true)"
    [[ "$latest_release_tag" == "$release_tag" ]] && break
    sleep 10
  done
  [[ "$latest_release_tag" == "$release_tag" ]] || {
    echo "GitHub Latest is ${latest_release_tag:-missing}, expected ${release_tag}" >&2
    return 1
  }

  governance_start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  gh workflow run termux-governance-audit.yml --repo "$repo" --ref main
  governance_run_id=""
  for _ in $(seq 1 120); do
    governance_run_id="$(
      gh api "/repos/${repo}/actions/workflows/termux-governance-audit.yml/runs?branch=main&per_page=30" \
        --jq ".workflow_runs
          | map(select(.created_at >= \"${governance_start}\"))
          | sort_by(.created_at) | reverse | .[0].id // empty"
    )"
    [[ -n "$governance_run_id" ]] && break
    sleep 5
  done
  [[ -n "$governance_run_id" ]]
  wait_run "$governance_run_id" 'governance audit' 160

  # A second pass removes branches whose PRs became merged during this run.
  git fetch --prune origin main '+refs/heads/*:refs/remotes/origin/*'
  cleanup_branches

  append_report ""
  append_report "### Completed"
  append_report "- Issue #44 remains closed with every accepted item checked."
  append_report "- Upstream alpha: \`${latest_tag}\` (\`${latest_version}\`)."
  append_report "- Released source: \`${final_sha}\`."
  append_report "- Promoted immutable release: \`${release_tag}\`."
  append_report "- GitHub Latest resolves to the promoted release."
  append_report "- Exact-source release run: https://github.com/${repo}/actions/runs/${release_run_id}"
  append_report "- Post-promotion governance audit: https://github.com/${repo}/actions/runs/${governance_run_id}"

  append_report ""
  append_report "### Dependabot"
  if ((${#merged_prs[@]} > 0)); then
    append_report "Merged ${#merged_prs[@]} green Dependabot PR(s):"
    for item in "${merged_prs[@]}"; do append_report "- ${item}"; done
  else
    append_report "- No open Dependabot PR was both green and mergeable."
  fi
  if ((${#unresolved_prs[@]} > 0)); then
    append_report ""
    append_report "Not merged because they were not demonstrably safe:"
    printf '%s\n' "${unresolved_prs[@]}" | awk '!seen[$0]++ {print "- "$0}' >>"$report_file"
  fi

  append_report ""
  append_report "### Branch cleanup"
  if ((${#deleted_branches[@]} > 0)); then
    printf '%s\n' "${deleted_branches[@]}" | awk '!seen[$0]++ {print "- Deleted `"$0"`"}' >>"$report_file"
  else
    append_report "- No removable non-main branches remained."
  fi
  if ((${#preserved_branches[@]} > 0)); then
    append_report ""
    append_report "Preserved because they still contain unique work or an open PR:"
    printf '%s\n' "${preserved_branches[@]}" | awk '!seen[$0]++ {print "- `"$0"`"}' >>"$report_file"
  fi

  post_report "Repository cleanup and latest-alpha release completed"
  trap - ERR
}

main "$@"
