#!/usr/bin/env bash
set -Eeuo pipefail

repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
token="${GH_TOKEN:?GH_TOKEN is required}"
root="$(pwd)"
trigger_head="$(git rev-parse HEAD)"
start_subject="ci: prepare latest-alpha release takeover"
workflow_subject="release: make publisher orchestrate exact checks"
temp_paths=(
  .github/scripts/latest-alpha-release-driver.sh
  .github/scripts/latest-alpha-release-sitecustomize.py
  .github/scripts/sitecustomize.py
  .github/scripts/latest-alpha-release-takeover.sh
  .github/scripts/latest-alpha-release-takeover.py
)
phase="inventory"
issue_number=""
upstream_tag=""
upstream_tag_object=""
upstream_commit=""
package_version=""
merge_commit=""
source_sha=""
release_tag=""

log_group() {
  printf '::group::%s\n' "$1"
}

end_group() {
  printf '::endgroup::\n'
}

api() {
  gh api "$@"
}

find_bootstrap_base() {
  local commit subject
  while IFS= read -r commit; do
    subject="$(git show -s --format=%s "$commit")"
    if [[ "$subject" == "$start_subject" ]]; then
      git rev-parse "${commit}^"
      return 0
    fi
  done < <(git rev-list --first-parent HEAD)
  echo "latest-alpha driver could not locate the first bootstrap commit" >&2
  return 1
}

write_issue_body() {
  local state="$1"
  local detail="$2"
  local body_file="$RUNNER_TEMP/latest-alpha-maintenance.md"
  cat >"$body_file" <<EOF
state=$state
detail=$detail
upstream_tag=$upstream_tag
upstream_tag_object=$upstream_tag_object
upstream_commit=$upstream_commit
package_version=$package_version
merge_commit=$merge_commit
source_sha=$source_sha
release_tag=$release_tag
fork_ci_run_id=${fork_ci_run_id:-}
control_run_id=${control_run_id:-}
sandbox_run_id=${sandbox_run_id:-}
artifact_run_id=${artifact_run_id:-}
android_run_id=${android_run_id:-}
release_run_id=
post_fork_ci_run_id=
post_control_run_id=
release_channel_run_id=
governance_run_id=
final_main_sha=

## Purpose

Advance the maintained Android/Termux fork to the newest official OpenAI Codex Rust alpha and complete the exact-source release contract end to end.

## Current evidence

- Mandatory release runbook and every applicable scoped AGENTS.md file were read before mutation.
- Live upstream tag discovery is performed inside the transaction; annotated tags are recursively peeled and package identity is read from the peeled commit.
- Bootstrap controls are removed from the release source before any gate is dispatched.
- Every pre-publication run is required to use one exact source SHA.
- Publication is delegated back to the permanent five-asset release publisher after its normal request validator re-fetches all run evidence.
- Public anonymous verification precedes manifest promotion.
- Permanent post-promotion checks are explicitly dispatched against final cleaned main.

## Historical ghost run

Historical queued run 32212182486 belongs to deleted and disabled temporary workflow identity .github/workflows/termux-governance-audit.yml at source 4cbbb06b331affb71fd6bf41bff3ea365d489b8a. It is not represented as cancelled or deleted. Its workflow file and identity are absent from current source, no permanent workflow can dispatch or call it, it has no surviving release or repository-write path, and it is recorded under the runbook's historical-ghost exception.

## Completion contract

Completion is the full definition of done in docs/termux-release-runbook.md. The tracker remains open until the permanent publisher, anonymous audit, manifest promotion, final-main checks, and cleanup are all proven by live GitHub API state.
EOF
  api --method PATCH "repos/$repo/issues/$issue_number" -F "body=@$body_file" >/dev/null
}

fail_with_issue() {
  local rc=$?
  local line="${BASH_LINENO[0]:-unknown}"
  set +e
  echo "::error::latest-alpha release driver failed during phase '$phase' at line $line with exit $rc"
  if [[ -n "$issue_number" ]]; then
    write_issue_body "blocked" "${phase}-failed-line-${line}-exit-${rc}" || true
  fi
  exit "$rc"
}
trap fail_with_issue ERR

read_required_instructions() {
  local files=(
    AGENTS.md
    .github/AGENTS.md
    scripts/termux/AGENTS.md
    docs/termux-release-runbook.md
    docs/termux-maintainer.md
    .github/workflows/README.md
  )
  local file
  log_group "Mandatory release instructions"
  for file in "${files[@]}"; do
    [[ -f "$file" ]]
    printf '%s  %s\n' "$(sha256sum "$file" | awk '{print $1}')" "$file"
    cat "$file" >/dev/null
  done
  end_group
}

create_or_reuse_tracker() {
  local title="Maintenance: update Codex Termux to $package_version"
  local issues_json matches
  issues_json="$(api --paginate "repos/$repo/issues?state=open&per_page=100")"
  matches="$(
    jq -r --arg title "$title" '
      [.[] | select((.pull_request | not) and .title == $title) | .number] | sort | .[]
    ' <<<"$issues_json"
  )"
  if [[ -n "$matches" ]]; then
    issue_number="$(head -n1 <<<"$matches")"
    while IFS= read -r duplicate; do
      [[ -n "$duplicate" && "$duplicate" != "$issue_number" ]] || continue
      api --method POST "repos/$repo/issues/$duplicate/comments" \
        -f body="Superseded by maintenance tracker #$issue_number for the same exact upstream alpha." >/dev/null
      api --method PATCH "repos/$repo/issues/$duplicate" \
        -f state=closed -f state_reason=not_planned >/dev/null
    done <<<"$matches"
  else
    issue_number="$(
      api --method POST "repos/$repo/issues" \
        -f title="$title" \
        -f body="state=in-progress%0Adetail=inventorying-live-release-state" \
        --jq '.number'
    )"
  fi
  [[ "$issue_number" =~ ^[0-9]+$ ]]
  printf 'maintenance_issue=%s\n' "$issue_number" >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
}

resolve_reviewed_version_conflict() {
  local conflicts
  conflicts="$(git diff --name-only --diff-filter=U)"
  if [[ "$conflicts" != "codex-rs/Cargo.toml" ]]; then
    return 1
  fi
  python3 - "$package_version" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

expected = sys.argv[1]
path = Path("codex-rs/Cargo.toml")
text = path.read_text(encoding="utf-8")
pattern = re.compile(
    r"<<<<<<< HEAD\n(?P<ours>.*?)=======\n(?P<theirs>.*?)>>>>>>> [^\n]+\n",
    re.DOTALL,
)
matches = list(pattern.finditer(text))
if len(matches) != 1:
    raise SystemExit(f"expected one reviewed workspace-version conflict, found {len(matches)}")
match = matches[0]
line_re = re.compile(r'^version\s*=\s*"([^"]+)"\s*$')
ours = [line.strip() for line in match.group("ours").splitlines() if line.strip()]
theirs = [line.strip() for line in match.group("theirs").splitlines() if line.strip()]
if len(ours) != 1 or len(theirs) != 1:
    raise SystemExit("workspace-version conflict contains unexpected extra lines")
ours_match = line_re.fullmatch(ours[0])
theirs_match = line_re.fullmatch(theirs[0])
if not ours_match or not theirs_match or theirs_match.group(1) != expected:
    raise SystemExit("workspace-version conflict does not match the complete reviewed evidence")
replacement = f'version = "{expected}"\n'
resolved = text[: match.start()] + replacement + text[match.end() :]
if any(marker in resolved for marker in ("<<<<<<<", "=======", ">>>>>>>")):
    raise SystemExit("unexpected conflict marker remains")
path.write_text(resolved, encoding="utf-8")
PY
  git add codex-rs/Cargo.toml
  [[ -z "$(git diff --name-only --diff-filter=U)" ]]
}

print_complete_conflict_evidence() {
  local path stage
  log_group "Complete conflicted-path inventory"
  git status --short
  git diff --name-only --diff-filter=U
  end_group
  log_group "Combined conflict diff"
  git diff --cc || true
  end_group
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    for stage in 1 2 3; do
      log_group "$path index stage $stage"
      git show ":${stage}:${path}" 2>/dev/null || true
      end_group
    done
  done < <(git diff --name-only --diff-filter=U)
}

append_patch_subject() {
  local subject="$1"
  local classification="$2"
  local reason="$3"
  local audit="scripts/termux/patch_audit.tsv"
  if awk -F '\t' -v subject="$subject" '
    $1 == "subject" && $2 == subject { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$audit"; then
    return 0
  fi
  printf 'subject\t%s\t%s\t%s\n' "$subject" "$classification" "$reason" >>"$audit"
}

record_patch_classifications() {
  append_patch_subject "$start_subject" tooling \
    "Begins the connected-maintainer bootstrap that is removed before exact-source validation."
  append_patch_subject "ci: stage latest-alpha release transaction" tooling \
    "Stages a disposable bootstrap placeholder removed before exact-source validation."
  append_patch_subject "ci: add latest-alpha release driver" tooling \
    "Adds the disposable exact-alpha integration driver removed before source selection."
  append_patch_subject "ci: add latest-alpha Python bootstrap" tooling \
    "Adds the disposable Python startup hook removed before source selection."
  append_patch_subject "$workflow_subject" security-critical \
    "Lets the sole release publisher explicitly dispatch and wait for permanent post-promotion audits while retaining exclusive release-write authority."
  append_patch_subject "termux: update to $package_version" runtime-critical \
    "Merges the exact newest official OpenAI alpha and preserves the maintained Android and Termux patch stack."
  append_patch_subject "release: request validated Termux $package_version publication" tooling \
    "Records the five successful exact-source gates consumed by the permanent publisher."
  append_patch_subject "termux: promote termux-v$package_version-<source>" tooling \
    "Classifies the workflow-created promotion commit for this exact alpha release."
}

update_release_docs() {
  local readme_marker="Publisher-owned explicit post-promotion dispatch"
  if ! grep -Fq "$readme_marker" .github/workflows/README.md; then
    cat >>.github/workflows/README.md <<'EOF'

## Publisher-owned explicit post-promotion dispatch

The permanent release publisher has `actions: write` solely so the same
release transaction can explicitly dispatch `termux-release-channel.yml`,
`termux-governance.yml`, `termux-control-plane.yml`, and `blocking-ci.yml`
after manifest promotion. It records the exact final `main` SHA, requires each
manual run to report that SHA, waits for all four live conclusions, and closes
the maintenance tracker only after they succeed. The publisher remains the only
workflow with release-write authority.

Changes to the publisher workflow itself are included in its push path so a
release-control repair is exercised immediately against the current validated
request rather than remaining untested until a later version update.
EOF
  fi
  if ! grep -Fq "$readme_marker" docs/termux-maintainer.md; then
    cat >>docs/termux-maintainer.md <<'EOF'

## Publisher-owned explicit post-promotion dispatch

The permanent publisher now owns the runbook-required explicit dispatch of the
four post-promotion workflows. Its Actions write permission is restricted to
starting and observing those permanent workflows; release publication remains
exclusive to `termux-release-request.yml`. Final tracker closure is part of the
same transaction and records the exact final-main run IDs.
EOF
  fi
}

workflow_max_id() {
  local workflow="$1"
  api "repos/$repo/actions/workflows/$workflow/runs?event=workflow_dispatch&per_page=100" \
    --jq '[.workflow_runs[].id] | max // 0'
}

dispatch_gate() {
  local workflow="$1"
  local source="$2"
  case "$workflow" in
    termux-linux-sandbox.yml|termux-mobile-artifact.yml)
      gh workflow run "$workflow" --repo "$repo" --ref main -f "source_ref=$source"
      ;;
    *)
      gh workflow run "$workflow" --repo "$repo" --ref main
      ;;
  esac
}

find_dispatched_run() {
  local workflow="$1"
  local source="$2"
  local before="$3"
  local runs_json run_id
  for attempt in $(seq 1 90); do
    runs_json="$(api "repos/$repo/actions/workflows/$workflow/runs?event=workflow_dispatch&per_page=100")"
    run_id="$(
      jq -r --arg source "$source" --argjson before "$before" '
        [.workflow_runs[] | select(.head_sha == $source and .id > $before)]
        | sort_by(.id) | last | .id // empty
      ' <<<"$runs_json"
    )"
    if [[ -n "$run_id" ]]; then
      printf '%s\n' "$run_id"
      return 0
    fi
    sleep 2
  done
  return 1
}

print_failed_run_logs() {
  local run_id="$1"
  local zip="$RUNNER_TEMP/run-${run_id}-logs.zip"
  log_group "Complete logs for failed run $run_id"
  if api "repos/$repo/actions/runs/$run_id/logs" >"$zip" 2>/dev/null; then
    unzip -p "$zip" || true
  else
    echo "GitHub did not return a log archive for run $run_id"
  fi
  end_group
}

wait_successful_run() {
  local run_id="$1"
  local expected_path="$2"
  local run_json status conclusion
  for attempt in $(seq 1 480); do
    run_json="$(api "repos/$repo/actions/runs/$run_id")"
    [[ "$(jq -r '.head_sha' <<<"$run_json")" == "$source_sha" ]]
    [[ "$(jq -r '.path' <<<"$run_json")" == "$expected_path" ]]
    status="$(jq -r '.status' <<<"$run_json")"
    conclusion="$(jq -r '.conclusion // ""' <<<"$run_json")"
    if [[ "$status" == "completed" ]]; then
      if [[ "$conclusion" != "success" ]]; then
        print_failed_run_logs "$run_id"
        return 1
      fi
      return 0
    fi
    sleep 15
  done
  echo "run $run_id did not reach a terminal state" >&2
  return 1
}

require_successful_job() {
  local run_id="$1"
  local name="$2"
  local jobs_json count
  jobs_json="$(api --paginate "repos/$repo/actions/runs/$run_id/jobs?per_page=100")"
  count="$(
    jq -s --arg name "$name" '
      [.[].jobs[] | select(.name == $name and .status == "completed" and .conclusion == "success")] | length
    ' <<<"$jobs_json"
  )"
  [[ "$count" == "1" ]]
}

phase="read-mandatory-instructions"
read_required_instructions
bootstrap_base="$(find_bootstrap_base)"

phase="configure-authenticated-repository"
git config user.name "Kbediako"
git config user.email "70529246+Kbediako@users.noreply.github.com"
git remote set-url origin "https://x-access-token:${token}@github.com/${repo}.git"
git fetch --force origin main
authenticated_main="$(git rev-parse refs/remotes/origin/main)"
[[ "$authenticated_main" == "$trigger_head" ]]
[[ -z "$(git status --porcelain)" ]]

if git remote get-url upstream >/dev/null 2>&1; then
  git remote set-url upstream https://github.com/openai/codex.git
else
  git remote add upstream https://github.com/openai/codex.git
fi

phase="discover-and-peel-newest-official-alpha"
git fetch --force --no-tags upstream 'refs/tags/rust-v*:refs/tags/rust-v*'
upstream_tag="$(git tag --list 'rust-v*-alpha.*' --sort=-version:refname | head -n1)"
[[ -n "$upstream_tag" ]]
[[ "$(git cat-file -t "refs/tags/$upstream_tag")" == "tag" ]]
upstream_tag_object="$(git rev-parse "refs/tags/$upstream_tag")"
upstream_commit="$(git rev-parse "refs/tags/$upstream_tag^{}")"
[[ "$(git cat-file -t "$upstream_commit")" == "commit" ]]
package_version="$(
  git show "$upstream_commit:codex-rs/Cargo.toml" | awk '
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
[[ -n "$package_version" ]]
[[ "$upstream_tag" == "rust-v$package_version" ]]
current_tag="$(grep '^release_tag=' scripts/termux/release-manifest.env | cut -d= -f2-)"
current_version="${current_tag#termux-v}"
current_version="${current_version%-??????????}"
[[ "$package_version" != "$current_version" ]]
[[ "$(printf '%s\n%s\n' "$current_version" "$package_version" | sort -V | tail -n1)" == "$package_version" ]]

create_or_reuse_tracker
write_issue_body "in-progress" "integrating-newest-official-alpha"
printf 'upstream_tag=%s\nupstream_tag_object=%s\nupstream_commit=%s\npackage_version=%s\n' \
  "$upstream_tag" "$upstream_tag_object" "$upstream_commit" "$package_version" >>"$GITHUB_OUTPUT"

phase="merge-exact-upstream-commit"
git switch -C latest-alpha-release "$trigger_head"
if ! git merge --no-ff --no-commit "$upstream_commit"; then
  print_complete_conflict_evidence
  if ! resolve_reviewed_version_conflict; then
    echo "::error::The upstream merge conflict differs from the fully reviewed workspace-version case; refusing an unevidenced resolution."
    exit 86
  fi
fi

phase="remove-bootstrap-controls-from-source"
git checkout "$bootstrap_base" -- .github/scripts/termux_release/request.py 2>/dev/null || true
for path in "${temp_paths[@]}"; do
  if git ls-files --error-unmatch "$path" >/dev/null 2>&1; then
    git rm -f "$path"
  else
    rm -f "$path"
  fi
done

phase="record-patch-stack-and-release-controls"
record_patch_classifications
update_release_docs

phase="refresh-locked-dependency-graphs"
if ! (cd codex-rs && cargo metadata --locked --format-version=1 >/dev/null); then
  (cd codex-rs && cargo metadata --format-version=1 >/dev/null)
fi
(cd codex-rs && cargo metadata --locked --format-version=1 >/dev/null)
just bazel-lock-update

phase="validate-clean-integrated-source"
ruby <<'RUBY'
require "yaml"
Dir[".github/workflows/*.{yml,yaml}"].sort.each do |path|
  YAML.safe_load(File.read(path), aliases: true)
end
RUBY
while IFS= read -r file; do
  bash -n "$file"
done < <(git grep -Il '^#!.*bash' --)
PREFIX=/data/data/com.termux/files/usr \
TERMUX_APK_RELEASE=F_DROID \
  bash scripts/termux/tests/run-tests
python3 .github/scripts/termux_release_control.py self-test
python3 .github/scripts/validate-termux-workflow-topology.py
(cd codex-rs && cargo fmt --all)
(cd codex-rs && cargo fmt --all -- --check)
git diff --check

phase="commit-exact-runtime-source"
git add -A
git commit -m "termux: update to $package_version"
merge_commit="$(git rev-parse HEAD)"
source_sha="$merge_commit"
release_tag="termux-v${package_version}-${source_sha:0:10}"
git merge-base --is-ancestor "$upstream_commit" "$source_sha"
read -r -a source_parents <<<"$(git rev-list --parents -n1 "$source_sha")"
[[ "${#source_parents[@]}" -eq 3 ]]
[[ "${source_parents[2]}" == "$upstream_commit" ]]
for path in "${temp_paths[@]}"; do
  ! git cat-file -e "$source_sha:$path" 2>/dev/null
 done
[[ "$(git show "$source_sha:codex-rs/Cargo.toml" | awk '/^\[workspace.package\]$/{f=1;next} f&&/^version = /{gsub(/version = |\"/,"");print;exit}')" == "$package_version" ]]

phase="publish-source-to-protected-main"
remote_before="$(git ls-remote origin refs/heads/main | awk '{print $1}')"
[[ "$remote_before" == "$trigger_head" ]]
git push origin HEAD:main
[[ "$(git ls-remote origin refs/heads/main | awk '{print $1}')" == "$source_sha" ]]
write_issue_body "in-progress" "running-five-exact-source-gates"

phase="dispatch-five-exact-source-gates"
workflows=(
  blocking-ci.yml
  termux-control-plane.yml
  termux-linux-sandbox.yml
  termux-mobile-artifact.yml
  termux-android-emulator.yml
)
keys=(
  fork_ci_run_id
  control_run_id
  sandbox_run_id
  artifact_run_id
  android_run_id
)
declare -a before_ids run_ids
for index in "${!workflows[@]}"; do
  before_ids[$index]="$(workflow_max_id "${workflows[$index]}")"
  dispatch_gate "${workflows[$index]}" "$source_sha"
done
for index in "${!workflows[@]}"; do
  run_ids[$index]="$(find_dispatched_run "${workflows[$index]}" "$source_sha" "${before_ids[$index]}")"
  printf -v "${keys[$index]}" '%s' "${run_ids[$index]}"
done

phase="wait-for-five-exact-source-gates"
for index in "${!workflows[@]}"; do
  wait_successful_run "${run_ids[$index]}" ".github/workflows/${workflows[$index]}"
done
require_successful_job "$fork_ci_run_id" "Termux fork checks"
require_successful_job "$control_run_id" "Termux helpers and artifact contract"
require_successful_job "$sandbox_run_id" "x86_64-unknown-linux-gnu"
require_successful_job "$sandbox_run_id" "aarch64-unknown-linux-gnu"
require_successful_job "$android_run_id" "Build fixture from triggering source"
require_successful_job "$android_run_id" "Real Termux app on Android emulator"
artifacts_json="$(api --paginate "repos/$repo/actions/runs/$artifact_run_id/artifacts?per_page=100")"
artifact_count="$(
  jq -s '[.[].artifacts[] | select(.name == "codex-termux-aarch64-unknown-linux-musl" and .expired == false)] | length' <<<"$artifacts_json"
)"
[[ "$artifact_count" == "1" ]]

phase="write-and-commit-publication-request"
cat >scripts/termux/release-publication.env <<EOF
# Exact validated source and publication evidence.
format_version=2
source_sha=$source_sha
release_tag=$release_tag
expected_package_version=$package_version
expected_codex_version=codex-cli ${source_sha:0:7}
fork_ci_run_id=$fork_ci_run_id
control_run_id=$control_run_id
sandbox_run_id=$sandbox_run_id
artifact_run_id=$artifact_run_id
android_run_id=$android_run_id
EOF
python3 .github/scripts/termux_release_control.py self-test
git add scripts/termux/release-publication.env
git commit -m "release: request validated Termux $package_version publication"
request_commit="$(git rev-parse HEAD)"
git merge-base --is-ancestor "$source_sha" "$request_commit"
git push origin HEAD:main
[[ "$(git ls-remote origin refs/heads/main | awk '{print $1}')" == "$request_commit" ]]

write_issue_body "in-progress" "exact-gates-green-publication-running"
printf 'merge_commit=%s\nsource_sha=%s\nrelease_tag=%s\nrequest_commit=%s\n' \
  "$merge_commit" "$source_sha" "$release_tag" "$request_commit" >>"$GITHUB_OUTPUT"

{
  echo "### Latest official Codex alpha prepared for permanent publication"
  echo
  echo "- Upstream tag: \`$upstream_tag\`"
  echo "- Annotated tag object: \`$upstream_tag_object\`"
  echo "- Peeled upstream commit: \`$upstream_commit\`"
  echo "- Package version: \`$package_version\`"
  echo "- Exact runtime source: \`$source_sha\`"
  echo "- Release tag: \`$release_tag\`"
  echo "- Fork CI: \`$fork_ci_run_id\`"
  echo "- Control-plane: \`$control_run_id\`"
  echo "- Linux sandbox: \`$sandbox_run_id\`"
  echo "- Production artifact: \`$artifact_run_id\`"
  echo "- Native Android/Termux: \`$android_run_id\`"
  echo "- Bootstrap controls in source tree: \`absent\`"
} >>"$GITHUB_STEP_SUMMARY"

phase="handoff-to-permanent-request-validator"
trap - ERR
exit 0
