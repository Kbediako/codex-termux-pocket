#!/usr/bin/env bash
set -Eeuo pipefail

upstream_tag="rust-v0.153.0-alpha.4"
upstream_tag_object="767248f1c50b650dbfca7b121bccb4110d00c891"
upstream_commit="c7348a8ffb32269e147817ad61918278401fb474"
package_version="0.153.0-alpha.4"
merge_subject="termux: update to 0.153.0-alpha.4"
staging_branch="automation/alpha1534-integration"
phase="initializing"
evidence_dir="${RUNNER_TEMP:?RUNNER_TEMP is required}/alpha1534-evidence"
mkdir -p "$evidence_dir"

collect_diagnostics() {
  set +e
  printf 'phase=%s\n' "$phase" >"$evidence_dir/phase.env"
  git status --short >"$evidence_dir/status.txt" 2>&1
  git diff --name-only --diff-filter=U >"$evidence_dir/conflicts.txt" 2>&1
  git diff --cc >"$evidence_dir/combined.diff" 2>&1
  git diff >"$evidence_dir/worktree.diff" 2>&1
  git log --oneline --decorate -40 >"$evidence_dir/recent-log.txt" 2>&1
  git rev-list --parents -n 10 HEAD >"$evidence_dir/recent-parents.txt" 2>&1
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    safe="$(printf '%s' "$path" | tr '/ ' '__')"
    for stage in 1 2 3; do
      git show ":${stage}:${path}" >"$evidence_dir/${safe}.stage${stage}" 2>/dev/null || true
    done
  done <"$evidence_dir/conflicts.txt"
}

print_conflict_evidence() {
  set +e
  echo "::group::Conflicted paths"
  cat "$evidence_dir/conflicts.txt" || true
  echo "::endgroup::"
  echo "::group::Combined conflict diff"
  cat "$evidence_dir/combined.diff" || true
  echo "::endgroup::"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    safe="$(printf '%s' "$path" | tr '/ ' '__')"
    for stage in 1 2 3; do
      echo "::group::${path} index stage ${stage}"
      cat "$evidence_dir/${safe}.stage${stage}" 2>/dev/null || true
      echo "::endgroup::"
    done
  done <"$evidence_dir/conflicts.txt"
}

on_error() {
  local rc=$?
  local line="${BASH_LINENO[0]:-unknown}"
  set +e
  collect_diagnostics
  printf 'line=%s\nexit=%s\n' "$line" "$rc" >>"$evidence_dir/phase.env"
  echo "::error::alpha.4 integration failed in phase ${phase} at line ${line} with exit ${rc}"
  exit "$rc"
}
trap on_error ERR

append_patch_audit() {
  local line
  line=$'subject\ttermux: update to 0.153.0-alpha.4\truntime-critical\tMerges the exact official 0.153.0-alpha.4 source and preserves the maintained Android and Termux runtime patch stack.'
  grep -Fqx "$line" scripts/termux/patch_audit.tsv || printf '%s\n' "$line" >>scripts/termux/patch_audit.tsv
}

resolve_evidenced_version_conflict() {
  mapfile -t conflicts < <(git diff --name-only --diff-filter=U)
  if (( ${#conflicts[@]} != 1 )) || [[ "${conflicts[0]}" != "codex-rs/Cargo.toml" ]]; then
    return 1
  fi

  python3 - <<'PY'
from pathlib import Path

path = Path("codex-rs/Cargo.toml")
text = path.read_text(encoding="utf-8")
conflict = """<<<<<<< HEAD
version = \"0.153.0-alpha.2\"
=======
version = \"0.153.0-alpha.4\"
>>>>>>> c7348a8ffb32269e147817ad61918278401fb474
"""
if text.count(conflict) != 1:
    raise SystemExit("workspace-version conflict does not match the complete reviewed evidence")
resolved = text.replace(conflict, 'version = "0.153.0-alpha.4"\n', 1)
if any(marker in resolved for marker in ("<<<<<<<", "=======", ">>>>>>>")):
    raise SystemExit("unexpected conflict marker remains after version resolution")
path.write_text(resolved, encoding="utf-8")
PY

  git add codex-rs/Cargo.toml
  [[ -z "$(git diff --name-only --diff-filter=U)" ]]
  echo "Resolved the sole reviewed conflict by taking the official alpha.4 workspace version."
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
if git ls-remote --exit-code --heads origin "refs/heads/${staging_branch}" >/dev/null 2>&1; then
  echo "::error::staging branch ${staging_branch} already exists; refusing to overwrite it"
  exit 1
fi

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
actual_package_version="$(
  git show "${upstream_commit}:codex-rs/Cargo.toml" | awk '
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
[[ "$actual_package_version" == "$package_version" ]]
echo "Verified ${upstream_tag} tag object ${upstream_tag_object} -> ${upstream_commit}."

phase="merging-exact-upstream-source"
if ! git merge --no-ff --no-commit "$upstream_commit"; then
  phase="reviewing-upstream-merge-conflict"
  collect_diagnostics
  print_conflict_evidence
  if ! resolve_evidenced_version_conflict; then
    echo "::error::The merge conflict differs from the complete reviewed evidence; refusing to guess a resolution."
    trap - ERR
    exit 86
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
(cd codex-rs && cargo fmt --all)
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

phase="publishing-integration-staging-branch"
git push origin "HEAD:refs/heads/${staging_branch}"
remote_staging="$(git ls-remote origin "refs/heads/${staging_branch}" | awk '{print $1}')"
[[ "$remote_staging" == "$merge_commit" ]]
remote_main="$(git ls-remote origin refs/heads/main | awk '{print $1}')"
[[ "$remote_main" == "$starting_head" ]]

{
  echo "### Exact upstream alpha.4 integration"
  echo
  echo "- Upstream tag: \`${upstream_tag}\`"
  echo "- Annotated tag object: \`${upstream_tag_object}\`"
  echo "- Peeled upstream commit: \`${upstream_commit}\`"
  echo "- Integration merge: \`${merge_commit}\`"
  echo "- Staging branch: \`${staging_branch}\`"
  echo "- Main remained unchanged: \`${starting_head}\`"
  echo "- Next boundary: direct cleanup of disposable controls on staging, then one fast-forward of clean source to main"
} >>"$GITHUB_STEP_SUMMARY"

echo "Integrated ${upstream_tag} as staged merge ${merge_commit}; main remains ${starting_head}."
