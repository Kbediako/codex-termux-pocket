#!/usr/bin/env bash
set -Eeuo pipefail

repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
issue_number="${ISSUE_NUMBER:?ISSUE_NUMBER is required}"
upstream_tag="rust-v0.152.0-alpha.1"
upstream_tag_object="757a7d182207d78dd1ed582062b41de381f33bb5"
upstream_commit="6d123b7e98b045f2796cb196e719b96a43d39a7a"
package_version="0.152.0-alpha.1"
merge_subject="termux: update to 0.152.0-alpha.1"
phase="initializing"
conflict_dir="${RUNNER_TEMP:?RUNNER_TEMP is required}/alpha1521-conflicts"
mkdir -p "$conflict_dir"

update_tracker() {
  local state="$1"
  local detail="$2"
  local merge_commit="${3:-}"
  local body payload
  body="$(cat <<EOF
state=${state}
detail=${detail}
integration_run_id=${GITHUB_RUN_ID}
upstream_tag=${upstream_tag}
upstream_tag_object=${upstream_tag_object}
upstream_commit=${upstream_commit}
package_version=${package_version}
merge_commit=${merge_commit}
source_sha=
release_tag=
fork_ci_run_id=
control_run_id=
sandbox_run_id=
artifact_run_id=
android_run_id=
release_run_id=
post_fork_ci_run_id=
post_control_run_id=
release_channel_run_id=
governance_run_id=
EOF
)"
  payload="$RUNNER_TEMP/alpha1521-issue.json"
  jq -n --arg body "$body" '{body:$body}' > "$payload"
  gh api --method PATCH "/repos/${repo}/issues/${issue_number}" \
    --input "$payload" >/dev/null
}

collect_conflicts() {
  set +e
  git status --short > "$conflict_dir/status.txt" 2>&1
  git diff --name-only --diff-filter=U > "$conflict_dir/conflicts.txt" 2>&1
  git diff --cc > "$conflict_dir/combined.diff" 2>&1
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    safe="$(printf '%s' "$path" | tr '/ ' '__')"
    for stage in 1 2 3; do
      git show ":${stage}:${path}" > "$conflict_dir/${safe}.stage${stage}" 2>/dev/null || true
    done
  done < "$conflict_dir/conflicts.txt"
}

resolve_verified_version_conflict() {
  mapfile -t conflicts < <(git diff --name-only --diff-filter=U)
  [[ "${#conflicts[@]}" -eq 1 ]]
  [[ "${conflicts[0]}" == "codex-rs/Cargo.toml" ]]

  python3 - "$upstream_commit" <<'PY'
from pathlib import Path
import re
import sys

upstream_commit = sys.argv[1]
path = Path("codex-rs/Cargo.toml")
text = path.read_text(encoding="utf-8")
pattern = re.compile(
    r'<<<<<<< HEAD\n'
    r'version = "0\.151\.0-alpha\.12"\n'
    r'=======\n'
    r'version = "0\.152\.0-alpha\.1"\n'
    r'>>>>>>> ' + re.escape(upstream_commit) + r'\n'
)
updated, count = pattern.subn('version = "0.152.0-alpha.1"\n', text)
if count != 1:
    raise SystemExit(f"expected one verified workspace-version conflict, found {count}")
if any(marker in updated for marker in ("<<<<<<<", "=======", ">>>>>>>")):
    raise SystemExit("unexpected conflict marker remains after guarded resolution")
path.write_text(updated, encoding="utf-8")
PY

  git add codex-rs/Cargo.toml
  [[ -z "$(git diff --name-only --diff-filter=U)" ]]
}

on_error() {
  local rc=$?
  local line="${BASH_LINENO[0]:-unknown}"
  set +e
  collect_conflicts
  update_tracker failed "${phase}-line-${line}-exit-${rc}"
  exit "$rc"
}
trap on_error ERR

phase="configuring-repository"
update_tracker running "$phase"
git config user.name "Kbediako"
git config user.email "70529246+Kbediako@users.noreply.github.com"

git fetch --force origin main
current_head="$(git rev-parse HEAD)"
origin_head="$(git rev-parse refs/remotes/origin/main)"
[[ "$current_head" == "$origin_head" ]] || {
  echo "::error::main changed after the integration run started: ${current_head} != ${origin_head}"
  exit 1
}
[[ -z "$(git status --porcelain)" ]]

if git remote get-url upstream >/dev/null 2>&1; then
  git remote set-url upstream https://github.com/openai/codex.git
else
  git remote add upstream https://github.com/openai/codex.git
fi

phase="fetching-and-peeling-upstream-tag"
update_tracker running "$phase"
git fetch --force --no-tags upstream \
  "refs/tags/${upstream_tag}:refs/tags/${upstream_tag}"
[[ "$(git cat-file -t "refs/tags/${upstream_tag}")" == "tag" ]]
[[ "$(git rev-parse "refs/tags/${upstream_tag}")" == "$upstream_tag_object" ]]
peeled="$(git rev-parse "refs/tags/${upstream_tag}^{}")"
[[ "$peeled" == "$upstream_commit" ]]

phase="merging-exact-upstream-source"
update_tracker running "$phase"
if ! git merge --no-ff --no-commit "$upstream_commit"; then
  collect_conflicts
  if resolve_verified_version_conflict; then
    echo "Resolved the sole verified workspace package-version conflict in favour of the exact upstream alpha.1 version."
  else
    conflicts="$(paste -sd, "$conflict_dir/conflicts.txt")"
    update_tracker failed "merge-conflicts:${conflicts}"
    trap - ERR
    exit 1
  fi
fi

phase="recording-fork-patch-classification"
audit_line=$'subject\ttermux: update to 0.152.0-alpha.1\truntime-critical\tMerges the exact official 0.152.0-alpha.1 source and reapplies the maintained Android and Termux runtime patch stack.'
grep -Fqx "$audit_line" scripts/termux/patch_audit.tsv || \
  printf '%s\n' "$audit_line" >> scripts/termux/patch_audit.tsv

phase="refreshing-locked-dependency-graph"
update_tracker running "$phase"
if ! (cd codex-rs && cargo metadata --locked --format-version=1 >/dev/null); then
  echo "Locked metadata is stale after the exact upstream merge; refreshing Cargo.lock."
  (cd codex-rs && cargo metadata --format-version=1 >/dev/null)
  (cd codex-rs && cargo metadata --locked --format-version=1 >/dev/null)
fi

phase="validating-integrated-tree"
ruby <<'RUBY'
require "yaml"
Dir[".github/workflows/*.{yml,yaml}"].sort.each do |path|
  YAML.safe_load(File.read(path), aliases: true)
end
RUBY
python3 .github/scripts/validate-termux-workflow-topology.py
bash -n .github/scripts/alpha1521-integrate.sh
(cd codex-rs && cargo fmt --all -- --check)

phase="committing-exact-upstream-merge"
update_tracker running "$phase"
git add -A
git commit -m "$merge_subject"
merge_commit="$(git rev-parse HEAD)"
git merge-base --is-ancestor "$upstream_commit" "$merge_commit"
parent_count="$(git rev-list --parents -n 1 "$merge_commit" | awk '{print NF - 1}')"
[[ "$parent_count" -ge 2 ]]

phase="publishing-merge-to-main"
update_tracker running "$phase" "$merge_commit"
git push origin HEAD:main
remote_main="$(git ls-remote origin refs/heads/main | awk '{print $1}')"
[[ "$remote_main" == "$merge_commit" ]]

trap - ERR
update_tracker integration_complete exact-upstream-merge-pushed "$merge_commit"

{
  echo "### Exact upstream alpha integration"
  echo
  echo "- Upstream tag: \`${upstream_tag}\`"
  echo "- Peeled upstream commit: \`${upstream_commit}\`"
  echo "- Merge commit: \`${merge_commit}\`"
  echo "- Status: pushed to \`main\`"
} >> "$GITHUB_STEP_SUMMARY"
