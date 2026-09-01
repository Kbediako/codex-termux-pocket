#!/usr/bin/env bash
set -Eeuo pipefail

upstream_tag="rust-v0.152.0-alpha.7.2"
upstream_tag_object="8aafdc4a83be6995dfb6dbf6b8e44330f6153015"
upstream_commit="d6b6badf5b71f341676bb5e4fcbfbe3bec1a0722"
package_version="0.152.0-alpha.7.2"
merge_subject="termux: update to 0.152.0-alpha.7.2"
phase="initializing"
conflict_dir="${RUNNER_TEMP:?RUNNER_TEMP is required}/alpha15272-conflicts"
mkdir -p "$conflict_dir"

collect_diagnostics() {
  set +e
  git status --short >"$conflict_dir/status.txt" 2>&1
  git diff --name-only --diff-filter=U >"$conflict_dir/conflicts.txt" 2>&1
  git diff --cc >"$conflict_dir/combined.diff" 2>&1
  git log --oneline --decorate -20 >"$conflict_dir/recent-log.txt" 2>&1
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    safe="$(printf '%s' "$path" | tr '/ ' '__')"
    for stage in 1 2 3; do
      git show ":${stage}:${path}" >"$conflict_dir/${safe}.stage${stage}" 2>/dev/null || true
    done
  done <"$conflict_dir/conflicts.txt"
}

on_error() {
  local rc=$?
  local line="${BASH_LINENO[0]:-unknown}"
  set +e
  collect_diagnostics
  printf 'phase=%s\nline=%s\nexit=%s\n' "$phase" "$line" "$rc" >"$conflict_dir/failure.env"
  exit "$rc"
}
trap on_error ERR

resolve_verified_workspace_version_conflict() {
  mapfile -t conflicts < <(git diff --name-only --diff-filter=U)
  [[ "${#conflicts[@]}" -eq 1 ]]
  [[ "${conflicts[0]}" == "codex-rs/Cargo.toml" ]]

  if ! python3 - <<'PY'
from pathlib import Path
import re

path = Path("codex-rs/Cargo.toml")
text = path.read_text(encoding="utf-8")
pattern = re.compile(
    r'<<<<<<< HEAD\n'
    r'version = "0\.151\.0-alpha\.12"\n'
    r'=======\n'
    r'version = "0\.152\.0-alpha\.7\.2"\n'
    r'>>>>>>> [^\n]+\n'
)
updated, count = pattern.subn('version = "0.152.0-alpha.7.2"\n', text)
if count != 1:
    raise SystemExit(f"expected one guarded workspace-version conflict, found {count}")
if any(marker in updated for marker in ("<<<<<<<", "=======", ">>>>>>>")):
    raise SystemExit("unexpected conflict marker remains after guarded resolution")
path.write_text(updated, encoding="utf-8")
PY
  then
    return 1
  fi

  if grep -R -n -E '^(<<<<<<<|=======|>>>>>>>)' codex-rs/Cargo.toml; then
    echo "::error::Conflict marker remains in codex-rs/Cargo.toml"
    return 1
  fi
  git add codex-rs/Cargo.toml
  [[ -z "$(git diff --name-only --diff-filter=U)" ]] || return 1
}

update_dotted_alpha_support() {
  python3 - <<'PY'
from pathlib import Path

def replace_once(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one occurrence, found {count}: {old!r}")
    file.write_text(text.replace(old, new), encoding="utf-8")

replace_once(
    "scripts/termux/maintainer-update-alpha",
    "Usage: maintainer-update-alpha [--tag rust-vX.Y.Z-alpha.N] [--lock-only]",
    "Usage: maintainer-update-alpha [--tag rust-vX.Y.Z-alpha.N[.P...]] [--lock-only]",
)
replace_once(
    "scripts/termux/maintainer-update-alpha",
    '[[ "$target_tag" =~ ^rust-v[0-9]+\\.[0-9]+\\.[0-9]+-alpha\\.[0-9]+$ ]] || \\',
    '[[ "$target_tag" =~ ^rust-v[0-9]+\\.[0-9]+\\.[0-9]+-alpha\\.[0-9]+(\\.[0-9]+)*$ ]] || \\',
)
replace_once(
    "scripts/termux/termux-mobile-lib.sh",
    'if [[ "$candidate_tag" =~ ^rust-v[0-9]+\\.[0-9]+\\.[0-9]+-alpha\\.[0-9]+$ ]]; then',
    'if [[ "$candidate_tag" =~ ^rust-v[0-9]+\\.[0-9]+\\.[0-9]+-alpha\\.[0-9]+(\\.[0-9]+)*$ ]]; then',
)
replace_once(
    "scripts/termux/tests/run-tests",
    "  git -C \"$repo\" tag rust-v0.148.0-alpha.5\n"
    "  git -C \"$repo\" tag rust-vrust-v9.0.0-alpha.99\n",
    "  git -C \"$repo\" tag rust-v0.148.0-alpha.5\n"
    "  git -C \"$repo\" tag rust-v0.148.0-alpha.5.1\n"
    "  git -C \"$repo\" tag rust-vrust-v9.0.0-alpha.99\n",
)
replace_once(
    "scripts/termux/tests/run-tests",
    "  assert_eq 'rust-v0.148.0-alpha.5' \"$(termux_latest_valid_alpha_tag \"$repo\" main)\" 'latest valid alpha merged into main'\n",
    "  assert_eq 'rust-v0.148.0-alpha.5.1' \"$(termux_latest_valid_alpha_tag \"$repo\" main)\" 'latest valid dotted alpha merged into main'\n",
)
replace_once(
    "scripts/termux/tests/run-tests",
    "  printf '#!/data/data/com.termux/files/usr/bin/bash\\nset -euo pipefail\\n%s\\n' \"$body\" >\"$path\"\n",
    "  printf '#!/usr/bin/env bash\\nset -euo pipefail\\n%s\\n' \"$body\" >\"$path\"\n",
)
replace_once(
    "scripts/termux/tests/run-tests",
    "  cat >\"$fake_bin/gh\" <<EOF\n#!/data/data/com.termux/files/usr/bin/bash\n",
    "  cat >\"$fake_bin/gh\" <<EOF\n#!/usr/bin/env bash\n",
)
PY
}

append_patch_audit() {
  local line
  line=$'subject\tci: stage exact 0.152.0-alpha.7.2 integration\ttooling\tTemporary protected-main integration job used to fetch, peel, and merge the exact official dotted alpha source; removed before selecting the release source.'
  grep -Fqx "$line" scripts/termux/patch_audit.tsv || printf '%s\n' "$line" >>scripts/termux/patch_audit.tsv

  line=$'subject\ttermux: update to 0.152.0-alpha.7.2\truntime-critical\tMerges the exact official 0.152.0-alpha.7.2 source and reapplies the maintained Android and Termux runtime patch stack.'
  grep -Fqx "$line" scripts/termux/patch_audit.tsv || printf '%s\n' "$line" >>scripts/termux/patch_audit.tsv

  line=$'subject\ttermux: repair hosted fixture interpreters for 0.152.0-alpha.7.2\ttooling\tUses env bash only in generated hosted-CI test doubles so executable validation remains covered without changing production Termux launchers.'
  grep -Fqx "$line" scripts/termux/patch_audit.tsv || printf '%s\n' "$line" >>scripts/termux/patch_audit.tsv
}

phase="configuring-repository"
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
git fetch --force --no-tags upstream \
  "refs/tags/${upstream_tag}:refs/tags/${upstream_tag}"
[[ "$(git cat-file -t "refs/tags/${upstream_tag}")" == "tag" ]]
[[ "$(git rev-parse "refs/tags/${upstream_tag}")" == "$upstream_tag_object" ]]
peeled="$(git rev-parse "refs/tags/${upstream_tag}^{}")"
[[ "$peeled" == "$upstream_commit" ]]

phase="merging-exact-upstream-source"
merge_failed=false
if ! git merge --no-ff --no-commit "$upstream_commit"; then
  merge_failed=true
fi
if [[ "$merge_failed" == "true" ]]; then
  collect_diagnostics
  if resolve_verified_workspace_version_conflict; then
    echo "Resolved the sole guarded workspace package-version conflict in favour of 0.152.0-alpha.7.2."
  else
    echo "::error::Unexpected upstream merge conflict; evidence was captured."
    trap - ERR
    exit 1
  fi
fi

phase="updating-dotted-alpha-support"
update_dotted_alpha_support

phase="recording-fork-patch-classification"
append_patch_audit

phase="refreshing-locked-dependency-graph"
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
while IFS= read -r file; do
  bash -n "$file"
done < <(git grep -Il '^#!.*bash' --)
PREFIX=/data/data/com.termux/files/usr bash scripts/termux/tests/run-tests
(cd codex-rs && cargo fmt --all -- --check)

phase="committing-exact-upstream-merge"
git add -A
git commit -m "$merge_subject"
merge_commit="$(git rev-parse HEAD)"
git merge-base --is-ancestor "$upstream_commit" "$merge_commit"
parent_count="$(git rev-list --parents -n 1 "$merge_commit" | awk '{print NF - 1}')"
[[ "$parent_count" -ge 2 ]]

phase="publishing-merge-to-main"
git push origin HEAD:main
remote_main="$(git ls-remote origin refs/heads/main | awk '{print $1}')"
[[ "$remote_main" == "$merge_commit" ]]

trap - ERR
{
  echo "### Exact upstream alpha integration"
  echo
  echo "- Upstream tag: \`${upstream_tag}\`"
  echo "- Annotated tag object: \`${upstream_tag_object}\`"
  echo "- Peeled upstream commit: \`${upstream_commit}\`"
  echo "- Merge commit: \`${merge_commit}\`"
  echo "- Dotted alpha selector: \`validated\`"
  echo "- Status: pushed to \`main\`"
} >>"$GITHUB_STEP_SUMMARY"
