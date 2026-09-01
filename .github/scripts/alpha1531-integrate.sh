#!/usr/bin/env bash
set -Eeuo pipefail

upstream_tag="rust-v0.153.0-alpha.1"
upstream_tag_object="5c6ff4778720d48159a37f058da09a00d58f727e"
upstream_commit="f2802f5e1e7981187122cb0953d455e8ddb9deab"
package_version="0.153.0-alpha.1"
merge_subject="termux: update to 0.153.0-alpha.1"
tracker_issue="102"
temporary_script=".github/scripts/alpha1531-integrate.sh"
release_request="scripts/termux/release-request.env"
phase="initializing"
evidence_dir="${RUNNER_TEMP:?RUNNER_TEMP is required}/alpha1531-evidence"
mkdir -p "$evidence_dir"

collect_diagnostics() {
  set +e
  printf 'phase=%s\n' "$phase" >"$evidence_dir/phase.env"
  git status --short >"$evidence_dir/status.txt" 2>&1
  git diff --name-only --diff-filter=U >"$evidence_dir/conflicts.txt" 2>&1
  git diff --cc >"$evidence_dir/combined.diff" 2>&1
  git diff >"$evidence_dir/worktree.diff" 2>&1
  git log --oneline --decorate -30 >"$evidence_dir/recent-log.txt" 2>&1
  git rev-list --parents -n 5 HEAD >"$evidence_dir/recent-parents.txt" 2>&1
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    safe="$(printf '%s' "$path" | tr '/ ' '__')"
    for stage in 1 2 3; do
      git show ":${stage}:${path}" >"$evidence_dir/${safe}.stage${stage}" 2>/dev/null || true
    done
  done <"$evidence_dir/conflicts.txt"
  if command -v gh >/dev/null 2>&1; then
    gh api "/repos/${GITHUB_REPOSITORY}/actions/runs?per_page=100" \
      >"$evidence_dir/recent-runs.json" 2>&1 || true
  fi
}

on_error() {
  local rc=$?
  local line="${BASH_LINENO[0]:-unknown}"
  set +e
  collect_diagnostics
  printf 'line=%s\nexit=%s\n' "$line" "$rc" >>"$evidence_dir/phase.env"
  exit "$rc"
}
trap on_error ERR

resolve_verified_merge_conflicts() {
  mapfile -t conflicts < <(git diff --name-only --diff-filter=U)
  (( ${#conflicts[@]} >= 1 && ${#conflicts[@]} <= 2 )) || return 1

  local path
  for path in "${conflicts[@]}"; do
    case "$path" in
      codex-rs/Cargo.toml|codex-rs/Cargo.lock) ;;
      *) return 1 ;;
    esac
  done

  if printf '%s\n' "${conflicts[@]}" | grep -Fxq 'codex-rs/Cargo.toml'; then
    python3 - <<'PY'
from pathlib import Path
import re

path = Path("codex-rs/Cargo.toml")
text = path.read_text(encoding="utf-8")
pattern = re.compile(
    r'<<<<<<< HEAD\n'
    r'version = "0\.152\.0-alpha\.7\.2"\n'
    r'=======\n'
    r'version = "0\.153\.0-alpha\.1"\n'
    r'>>>>>>> [^\n]+\n'
)
updated, count = pattern.subn('version = "0.153.0-alpha.1"\n', text)
if count != 1:
    raise SystemExit(f"expected one guarded workspace-version conflict, found {count}")
if any(marker in updated for marker in ("<<<<<<<", "=======", ">>>>>>>")):
    raise SystemExit("unexpected conflict marker remains in Cargo.toml")
path.write_text(updated, encoding="utf-8")
PY
    git add codex-rs/Cargo.toml
  fi

  if printf '%s\n' "${conflicts[@]}" | grep -Fxq 'codex-rs/Cargo.lock'; then
    git checkout --ours -- codex-rs/Cargo.lock
    git add codex-rs/Cargo.lock
  fi

  [[ -z "$(git diff --name-only --diff-filter=U)" ]]
}

append_patch_audit() {
  local line
  line=$'subject\ttermux: update to 0.153.0-alpha.1\truntime-critical\tMerges the exact official 0.153.0-alpha.1 source and preserves the maintained Android and Termux runtime patch stack.'
  grep -Fqx "$line" scripts/termux/patch_audit.tsv || printf '%s\n' "$line" >>scripts/termux/patch_audit.tsv
}

manifest_value_from_commit() {
  local commit="$1"
  local key="$2"
  git show "${commit}:${release_request}" | sed -n "s/^${key}=//p"
}

exact_run_json() {
  local source_sha="$1"
  local workflow_path="$2"
  gh api "/repos/${GITHUB_REPOSITORY}/actions/runs?head_sha=${source_sha}&per_page=100" \
    --jq "[.workflow_runs[] | select(.path == \"${workflow_path}\")] | sort_by(.id)"
}

select_reusable_run() {
  local source_sha="$1"
  local workflow_path="$2"
  local runs
  runs="$(exact_run_json "$source_sha" "$workflow_path")"
  jq -r '
    [
      .[]
      | select(
          (.status != "completed")
          or (.conclusion == "success")
        )
    ]
    | last
    | .id // empty
  ' <<<"$runs"
}

fail_on_existing_failed_run() {
  local source_sha="$1"
  local workflow_path="$2"
  local runs failed
  runs="$(exact_run_json "$source_sha" "$workflow_path")"
  failed="$(
    jq -r '
      [
        .[]
        | select(
            .status == "completed"
            and .conclusion != "success"
            and .conclusion != "skipped"
          )
      ]
      | last
      | .id // empty
    ' <<<"$runs"
  )"
  if [[ -n "$failed" ]]; then
    echo "::error::Exact-source run ${failed} for ${workflow_path} already failed. Inspect its complete job log before any rerun."
    return 1
  fi
}

wait_for_automatic_run() {
  local source_sha="$1"
  local workflow_path="$2"
  local deadline=$((SECONDS + 75))
  local id
  while (( SECONDS < deadline )); do
    id="$(select_reusable_run "$source_sha" "$workflow_path")"
    if [[ -n "$id" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
    fail_on_existing_failed_run "$source_sha" "$workflow_path"
    sleep 5
  done
  return 1
}

dispatch_and_find_run() {
  local source_sha="$1"
  local workflow_file="$2"
  local workflow_path=".github/workflows/${workflow_file}"
  local source_input="${3:-no}"
  local id

  id="$(select_reusable_run "$source_sha" "$workflow_path")"
  if [[ -n "$id" ]]; then
    printf '%s\n' "$id"
    return 0
  fi
  fail_on_existing_failed_run "$source_sha" "$workflow_path"

  if [[ "$source_input" == "yes" ]]; then
    gh workflow run "$workflow_file" \
      --repo "$GITHUB_REPOSITORY" \
      --ref main \
      -f "source_ref=${source_sha}"
  else
    gh workflow run "$workflow_file" \
      --repo "$GITHUB_REPOSITORY" \
      --ref main
  fi

  local deadline=$((SECONDS + 120))
  while (( SECONDS < deadline )); do
    id="$(select_reusable_run "$source_sha" "$workflow_path")"
    if [[ -n "$id" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
    fail_on_existing_failed_run "$source_sha" "$workflow_path"
    sleep 5
  done

  echo "::error::Dispatched ${workflow_file}, but no exact-source run appeared for ${source_sha}."
  return 1
}

phase="configuring-repository"
git config user.name "Kbediako"
git config user.email "70529246+Kbediako@users.noreply.github.com"
git fetch --force origin main
starting_head="$(git rev-parse HEAD)"
origin_head="$(git rev-parse refs/remotes/origin/main)"
[[ "$starting_head" == "$origin_head" ]] || {
  echo "::error::main moved before integration: ${starting_head} != ${origin_head}"
  exit 1
}
[[ -z "$(git status --porcelain)" ]]

if git remote get-url upstream >/dev/null 2>&1; then
  git remote set-url upstream https://github.com/openai/codex.git
else
  git remote add upstream https://github.com/openai/codex.git
fi

phase="fetching-and-peeling-exact-upstream-tag"
git fetch --force --no-tags upstream \
  "refs/tags/${upstream_tag}:refs/tags/${upstream_tag}"
[[ "$(git cat-file -t "refs/tags/${upstream_tag}")" == "tag" ]]
[[ "$(git rev-parse "refs/tags/${upstream_tag}")" == "$upstream_tag_object" ]]
peeled="$(git rev-parse "refs/tags/${upstream_tag}^{}")"
[[ "$peeled" == "$upstream_commit" ]]
[[ "$(git show "${upstream_commit}:codex-rs/Cargo.toml" | awk '
  /^\[workspace\.package\]$/ { in_package=1; next }
  /^\[/ && in_package { exit }
  in_package && /^version[[:space:]]*=/ {
    value=$0
    sub(/^[^=]*=[[:space:]]*"/, "", value)
    sub(/".*$/, "", value)
    print value
    exit
  }
')" == "$package_version" ]]

phase="merging-exact-upstream-source"
merge_failed=false
if ! git merge --no-ff --no-commit "$upstream_commit"; then
  merge_failed=true
fi
if [[ "$merge_failed" == "true" ]]; then
  collect_diagnostics
  if resolve_verified_merge_conflicts; then
    echo "Resolved only the guarded workspace version/lockfile conflicts."
  else
    echo "::error::Unexpected upstream merge conflict; complete evidence was captured."
    trap - ERR
    exit 1
  fi
fi

phase="recording-fork-patch-classification"
append_patch_audit

phase="refreshing-locked-dependency-graphs"
if ! (cd codex-rs && cargo metadata --locked --format-version=1 >/dev/null); then
  echo "Locked Cargo metadata is stale after the exact upstream merge; refreshing Cargo.lock."
  (cd codex-rs && cargo metadata --format-version=1 >/dev/null)
fi
(cd codex-rs && cargo metadata --locked --format-version=1 >/dev/null)
just bazel-lock-update

phase="validating-integrated-tree"
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
(cd codex-rs && just fmt)
(cd codex-rs && cargo fmt --all -- --check)
git diff --check

phase="committing-exact-upstream-merge"
git add -A
git commit -m "$merge_subject"
merge_commit="$(git rev-parse HEAD)"
git merge-base --is-ancestor "$upstream_commit" "$merge_commit"
read -r -a parents <<<"$(git rev-list --parents -n 1 "$merge_commit")"
[[ "${#parents[@]}" -eq 3 ]]
[[ "${parents[2]}" == "$upstream_commit" ]]

phase="publishing-merge-to-main"
git push origin HEAD:main
remote_main="$(git ls-remote origin refs/heads/main | awk '{print $1}')"
[[ "$remote_main" == "$merge_commit" ]]

{
  echo "### Exact upstream alpha integration"
  echo
  echo "- Upstream tag: \`${upstream_tag}\`"
  echo "- Annotated tag object: \`${upstream_tag_object}\`"
  echo "- Peeled upstream commit: \`${upstream_commit}\`"
  echo "- Integration merge: \`${merge_commit}\`"
  echo "- Status: exact merge pushed; awaiting direct cleanup/source commit"
} >>"$GITHUB_STEP_SUMMARY"

phase="waiting-for-clean-source-selection"
deadline=$((SECONDS + 3600))
source_sha=""
while (( SECONDS < deadline )); do
  git fetch --force origin main
  candidate="$(git rev-parse refs/remotes/origin/main)"
  if [[ "$candidate" == "$merge_commit" ]]; then
    sleep 5
    continue
  fi

  git merge-base --is-ancestor "$merge_commit" "$candidate" || {
    echo "::error::main moved to a non-descendant while awaiting cleanup: ${candidate}"
    exit 1
  }

  if git cat-file -e "${candidate}:${temporary_script}" 2>/dev/null; then
    sleep 5
    continue
  fi

  blocking_ci="$(git show "${candidate}:.github/workflows/blocking-ci.yml")"
  if grep -Eq '(^|[[:space:]])issues:|alpha1531|Integrate exact 0\.153\.0-alpha\.1' <<<"$blocking_ci"; then
    sleep 5
    continue
  fi

  [[ "$(manifest_value_from_commit "$candidate" format_version)" == "3" ]]
  [[ "$(manifest_value_from_commit "$candidate" source_mode)" == "workflow-head" ]]
  [[ "$(manifest_value_from_commit "$candidate" release_tag_prefix)" == "termux-v0.153.0-alpha.1" ]]
  [[ "$(manifest_value_from_commit "$candidate" expected_package_version)" == "$package_version" ]]

  git merge-base --is-ancestor "$upstream_commit" "$candidate"
  source_sha="$candidate"
  break
done
[[ -n "$source_sha" ]] || {
  echo "::error::Timed out waiting for a clean exact-source commit."
  exit 1
}

phase="discovering-or-dispatching-exact-source-gates"
# Give connector-authored push workflows time to register before dispatching
# anything manually, so the transaction never races itself.
fork_ci_run_id="$(
  wait_for_automatic_run "$source_sha" ".github/workflows/blocking-ci.yml" \
    || dispatch_and_find_run "$source_sha" "blocking-ci.yml"
)"
control_run_id="$(
  wait_for_automatic_run "$source_sha" ".github/workflows/termux-control-plane.yml" \
    || dispatch_and_find_run "$source_sha" "termux-control-plane.yml"
)"
android_run_id="$(
  wait_for_automatic_run "$source_sha" ".github/workflows/termux-android-emulator.yml" \
    || dispatch_and_find_run "$source_sha" "termux-android-emulator.yml"
)"
sandbox_run_id="$(
  dispatch_and_find_run "$source_sha" "termux-linux-sandbox.yml" yes
)"
artifact_run_id="$(
  dispatch_and_find_run "$source_sha" "termux-mobile-artifact.yml" yes
)"

for id in \
  "$fork_ci_run_id" \
  "$control_run_id" \
  "$sandbox_run_id" \
  "$artifact_run_id" \
  "$android_run_id"; do
  [[ "$id" =~ ^[0-9]+$ ]]
done

trap - ERR
{
  echo
  echo "### Clean exact-source gate dispatch"
  echo
  echo "- Clean runtime source: \`${source_sha}\`"
  echo "- Fork CI run: \`${fork_ci_run_id}\`"
  echo "- Control-plane run: \`${control_run_id}\`"
  echo "- Linux sandbox run: \`${sandbox_run_id}\`"
  echo "- Production ARM64 artifact run: \`${artifact_run_id}\`"
  echo "- Native Android/Termux run: \`${android_run_id}\`"
  echo "- Temporary integration source is absent from the selected runtime tree."
} >>"$GITHUB_STEP_SUMMARY"
