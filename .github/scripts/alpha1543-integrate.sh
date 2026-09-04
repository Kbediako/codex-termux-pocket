#!/usr/bin/env bash
set -Eeuo pipefail

readonly BASE_MAIN_SHA="8dcfde2341f272517f427bac090279508ae6825f"
readonly STAGING_BRANCH="automation/alpha1543-integration"
readonly SETUP_SUBJECT="ci: stage exact alpha.3 integration"
readonly TRIGGER_SUBJECT="ci: trigger exact alpha.3 integration"
readonly UPSTREAM_TAG="rust-v0.154.0-alpha.3"
readonly UPSTREAM_TAG_OBJECT="b20bd605db8cecf55db6d370a4cb71842bfdfa32"
readonly UPSTREAM_COMMIT="d58a64e690508a752c6a5a466ea752808849b7e2"
readonly PACKAGE_VERSION="0.154.0-alpha.3"
readonly PREVIOUS_VERSION="0.154.0-alpha.1"
readonly MERGE_SUBJECT="termux: update to 0.154.0-alpha.3"
readonly EXEC_PLAN=".release-engineering/alpha1543-execplan.md"
readonly FIRST_EVIDENCE_RUN_ID="33836487971"
readonly FIRST_EVIDENCE_JOB_ID="100909965260"
readonly FIRST_EVIDENCE_ARTIFACT_ID="9923445542"
readonly EVIDENCE_DIR="${RUNNER_TEMP:?RUNNER_TEMP is required}/alpha1543-integration-evidence"

phase="initializing"
mkdir -p "$EVIDENCE_DIR"

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
  '
}

collect_diagnostics() {
  set +e
  printf 'phase=%s\n' "$phase" >"$EVIDENCE_DIR/phase.env"
  printf 'head=%s\n' "$(git rev-parse HEAD 2>/dev/null || true)" >>"$EVIDENCE_DIR/phase.env"
  printf 'branch=%s\n' "$(git branch --show-current 2>/dev/null || true)" >>"$EVIDENCE_DIR/phase.env"
  git status --short >"$EVIDENCE_DIR/status.txt" 2>&1
  git diff --name-only --diff-filter=U >"$EVIDENCE_DIR/conflicts.txt" 2>&1
  git diff --cc >"$EVIDENCE_DIR/combined.diff" 2>&1
  git diff >"$EVIDENCE_DIR/worktree.diff" 2>&1
  git diff --cached >"$EVIDENCE_DIR/index.diff" 2>&1
  git log --oneline --decorate -50 >"$EVIDENCE_DIR/recent-log.txt" 2>&1
  git rev-list --parents -n 12 HEAD >"$EVIDENCE_DIR/recent-parents.txt" 2>&1
  git remote -v >"$EVIDENCE_DIR/remotes.txt" 2>&1
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    safe="$(printf '%s' "$path" | tr '/ ' '__')"
    for stage in 1 2 3; do
      git show ":${stage}:${path}" >"$EVIDENCE_DIR/${safe}.stage${stage}" 2>/dev/null || true
    done
  done <"$EVIDENCE_DIR/conflicts.txt"
}

print_conflict_evidence() {
  set +e
  echo "::group::Conflicted paths"
  cat "$EVIDENCE_DIR/conflicts.txt" || true
  echo "::endgroup::"
  echo "::group::Combined conflict diff"
  cat "$EVIDENCE_DIR/combined.diff" || true
  echo "::endgroup::"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    safe="$(printf '%s' "$path" | tr '/ ' '__')"
    for stage in 1 2 3; do
      echo "::group::${path} index stage $stage"
      cat "$EVIDENCE_DIR/${safe}.stage${stage}" 2>/dev/null || true
      echo "::endgroup::"
    done
  done <"$EVIDENCE_DIR/conflicts.txt"
}

on_error() {
  local rc=$?
  local line="${BASH_LINENO[0]:-unknown}"
  set +e
  collect_diagnostics
  printf 'line=%s\nexit=%s\n' "$line" "$rc" >>"$EVIDENCE_DIR/phase.env"
  echo "::error::alpha.3 integration failed in phase $phase at line $line with exit $rc"
  exit "$rc"
}
trap on_error ERR

append_patch_audit() {
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

phase="configuring-clean-staging-checkout"
git config user.name "Kbediako"
git config user.email "70529246+Kbediako@users.noreply.github.com"
git fetch --force origin main "+refs/heads/${STAGING_BRANCH}:refs/remotes/origin/${STAGING_BRANCH}"
remote_main="$(git rev-parse refs/remotes/origin/main)"
remote_staging="$(git rev-parse "refs/remotes/origin/${STAGING_BRANCH}")"
[[ "$remote_main" == "$BASE_MAIN_SHA" ]] || {
  echo "::error::protected main moved before integration: $remote_main != $BASE_MAIN_SHA"
  exit 1
}
git checkout -B alpha1543-work "$remote_staging"
[[ -z "$(git status --porcelain)" ]]
git merge-base --is-ancestor "$BASE_MAIN_SHA" HEAD
[[ "$(git show -s --format=%s HEAD)" == "$TRIGGER_SUBJECT" ]]

phase="squashing-and-classifying-staging-controls"
append_patch_audit "$SETUP_SUBJECT" tooling "Temporary staging-branch job, ExecPlan, and helper used to integrate the exact official 0.154.0-alpha.3 source; removed before selecting the release source."
append_patch_audit "$TRIGGER_SUBJECT" tooling "Triggers the isolated exact-alpha integration job after its reviewed workflow and helper exist on the staging branch; removed from the clean source by squashing."
git reset --soft "$BASE_MAIN_SHA"
git add -A
git commit -m "$SETUP_SUBJECT"
setup_commit="$(git rev-parse HEAD)"
git push "--force-with-lease=refs/heads/${STAGING_BRANCH}:${remote_staging}" origin "HEAD:refs/heads/${STAGING_BRANCH}"
[[ "$(git ls-remote origin "refs/heads/${STAGING_BRANCH}" | awk '{print $1}')" == "$setup_commit" ]]
[[ "$(git ls-remote origin refs/heads/main | awk '{print $1}')" == "$BASE_MAIN_SHA" ]]

phase="fetching-and-peeling-exact-upstream-tag"
if git remote get-url upstream >/dev/null 2>&1; then
  git remote set-url upstream https://github.com/openai/codex.git
else
  git remote add upstream https://github.com/openai/codex.git
fi
git fetch --force --no-tags upstream "refs/tags/${UPSTREAM_TAG}:refs/tags/${UPSTREAM_TAG}"
[[ "$(git cat-file -t "refs/tags/${UPSTREAM_TAG}")" == "tag" ]]
[[ "$(git rev-parse "refs/tags/${UPSTREAM_TAG}")" == "$UPSTREAM_TAG_OBJECT" ]]
peeled="$(git rev-parse "refs/tags/${UPSTREAM_TAG}^{}")"
[[ "$peeled" == "$UPSTREAM_COMMIT" ]]
actual_version="$(git show "${UPSTREAM_COMMIT}:codex-rs/Cargo.toml" | workspace_version)"
[[ "$actual_version" == "$PACKAGE_VERSION" ]]
printf 'upstream_tag=%s\nupstream_tag_object=%s\nupstream_commit=%s\npackage_version=%s\n' "$UPSTREAM_TAG" "$UPSTREAM_TAG_OBJECT" "$UPSTREAM_COMMIT" "$PACKAGE_VERSION" >"$EVIDENCE_DIR/upstream.env"

phase="merging-exact-upstream-source"
if git merge --no-ff --no-commit "$UPSTREAM_COMMIT"; then
  [[ -z "$(git diff --name-only --diff-filter=U)" ]]
else
  phase="applying-evidence-reviewed-version-resolution"
  collect_diagnostics
  print_conflict_evidence

  mapfile -t conflicts < <(git diff --name-only --diff-filter=U)
  if (( ${#conflicts[@]} != 1 )) || [[ "${conflicts[0]:-}" != "codex-rs/Cargo.toml" ]]; then
    echo "::error::reviewed evidence permits only codex-rs/Cargo.toml; observed: ${conflicts[*]:-none}"
    exit 1
  fi

  base_stage="$EVIDENCE_DIR/codex-rs_Cargo.toml.stage1.reviewed"
  ours_stage="$EVIDENCE_DIR/codex-rs_Cargo.toml.stage2.reviewed"
  theirs_stage="$EVIDENCE_DIR/codex-rs_Cargo.toml.stage3.reviewed"
  resolved_file="$EVIDENCE_DIR/codex-rs_Cargo.toml.resolved"
  git show :1:codex-rs/Cargo.toml >"$base_stage"
  git show :2:codex-rs/Cargo.toml >"$ours_stage"
  git show :3:codex-rs/Cargo.toml >"$theirs_stage"

  python3 - "$base_stage" "$ours_stage" "$theirs_stage" "$resolved_file" "$PREVIOUS_VERSION" "$PACKAGE_VERSION" <<'PY'
from __future__ import annotations

import difflib
import re
import sys
from pathlib import Path

base_path, ours_path, theirs_path, resolved_path = map(Path, sys.argv[1:5])
previous_version, package_version = sys.argv[5:7]


def normalize_and_resolve(text: str, replacement: str | None) -> tuple[str, str]:
    in_package = False
    found = False
    version = ""
    output: list[str] = []
    for line in text.splitlines(keepends=True):
        body = line.rstrip("\r\n")
        newline = line[len(body) :]
        stripped = body.strip()
        if stripped == "[workspace.package]":
            in_package = True
            output.append(line)
            continue
        if in_package and stripped.startswith("["):
            in_package = False
        if in_package:
            match = re.fullmatch(r'(\s*version\s*=\s*")([^"]+)("\s*)', body)
            if match:
                if found:
                    raise SystemExit("multiple workspace.package version lines")
                found = True
                version = match.group(2)
                value = "__REVIEWED_VERSION__" if replacement is None else replacement
                output.append(f"{match.group(1)}{value}{match.group(3)}{newline}")
                continue
        output.append(line)
    if not found:
        raise SystemExit("missing workspace.package version line")
    return version, "".join(output)

base_text = base_path.read_text(encoding="utf-8")
ours_text = ours_path.read_text(encoding="utf-8")
theirs_text = theirs_path.read_text(encoding="utf-8")
base_version, _ = normalize_and_resolve(base_text, None)
ours_version, ours_normalized = normalize_and_resolve(ours_text, None)
theirs_version, theirs_normalized = normalize_and_resolve(theirs_text, None)

if base_version != "0.0.0":
    raise SystemExit(f"unexpected merge-base workspace version: {base_version}")
if ours_version != previous_version:
    raise SystemExit(f"unexpected maintained workspace version: {ours_version}")
if theirs_version != package_version:
    raise SystemExit(f"unexpected upstream workspace version: {theirs_version}")
if ours_normalized != theirs_normalized:
    diff = "".join(
        difflib.unified_diff(
            ours_normalized.splitlines(keepends=True),
            theirs_normalized.splitlines(keepends=True),
            fromfile="stage2-normalized",
            tofile="stage3-normalized",
        )
    )
    raise SystemExit("Cargo.toml stages differ beyond the reviewed version line:\n" + diff[:8000])

_, resolved = normalize_and_resolve(ours_text, package_version)
resolved_version, resolved_normalized = normalize_and_resolve(resolved, None)
if resolved_version != package_version or resolved_normalized != ours_normalized:
    raise SystemExit("resolved Cargo.toml does not match the reviewed structure")
resolved_path.write_text(resolved, encoding="utf-8")
PY

  cp "$resolved_file" codex-rs/Cargo.toml
  git add codex-rs/Cargo.toml
  mapfile -t unresolved < <(git diff --name-only --diff-filter=U)
  (( ${#unresolved[@]} == 0 ))
  [[ "$(workspace_version <codex-rs/Cargo.toml)" == "$PACKAGE_VERSION" ]]
  {
    printf 'reviewed_run_id=%s\n' "$FIRST_EVIDENCE_RUN_ID"
    printf 'reviewed_job_id=%s\n' "$FIRST_EVIDENCE_JOB_ID"
    printf 'reviewed_artifact_id=%s\n' "$FIRST_EVIDENCE_ARTIFACT_ID"
    printf 'conflict_path=codex-rs/Cargo.toml\n'
    printf 'base_version=0.0.0\n'
    printf 'maintained_version=%s\n' "$PREVIOUS_VERSION"
    printf 'upstream_version=%s\n' "$PACKAGE_VERSION"
    printf 'resolution=replace-reviewed-workspace-version-only\n'
  } >"$EVIDENCE_DIR/resolution.env"
fi

phase="classifying-integration-merge"
append_patch_audit "$MERGE_SUBJECT" runtime-critical "Merges the exact official 0.154.0-alpha.3 source and preserves the maintained Android and Termux runtime patch stack."

phase="refreshing-locked-dependency-graphs"
if ! (cd codex-rs && cargo metadata --locked --format-version=1 >/dev/null); then
  echo "Locked Cargo metadata is stale after the exact alpha.3 merge; refreshing Cargo.lock."
  (cd codex-rs && cargo metadata --format-version=1 >/dev/null)
fi
(cd codex-rs && cargo metadata --locked --format-version=1 >/dev/null)
just bazel-lock-update
(cd codex-rs && cargo metadata --locked --format-version=1 >/dev/null)

phase="running-supported-pre-source-validation"
ruby <<'RUBY'
require "yaml"
Dir[".github/workflows/*.{yml,yaml}"].sort.each do |path|
  YAML.safe_load(File.read(path), aliases: true)
end
RUBY
while IFS= read -r file; do
  bash -n "$file"
done < <(git grep -Il '^#!.*bash' --)
PREFIX=/data/data/com.termux/files/usr TERMUX_APK_RELEASE=F_DROID bash scripts/termux/tests/run-tests
python3 .github/scripts/termux_release_control.py self-test
(cd codex-rs && cargo fmt --all)
(cd codex-rs && cargo fmt --all -- --check)
git diff --check

phase="committing-exact-upstream-merge"
git add -A
git commit -m "$MERGE_SUBJECT"
merge_commit="$(git rev-parse HEAD)"
git merge-base --is-ancestor "$UPSTREAM_COMMIT" "$merge_commit"
read -r -a parents <<<"$(git rev-list --parents -n 1 "$merge_commit")"
[[ "${#parents[@]}" -eq 3 ]]
[[ "${parents[2]}" == "$UPSTREAM_COMMIT" ]]
{
  printf 'setup_commit=%s\n' "$setup_commit"
  printf 'merge_commit=%s\n' "$merge_commit"
  printf 'second_parent=%s\n' "${parents[2]}"
} >>"$EVIDENCE_DIR/upstream.env"

phase="publishing-reviewed-merge-to-staging"
git push "--force-with-lease=refs/heads/${STAGING_BRANCH}:${setup_commit}" origin "HEAD:refs/heads/${STAGING_BRANCH}"
remote_after="$(git ls-remote origin "refs/heads/${STAGING_BRANCH}" | awk '{print $1}')"
[[ "$remote_after" == "$merge_commit" ]]
[[ "$(git ls-remote origin refs/heads/main | awk '{print $1}')" == "$BASE_MAIN_SHA" ]]

{
  echo "### Exact upstream alpha.3 integration"
  echo
  echo "- Upstream tag: \`${UPSTREAM_TAG}\`"
  echo "- Annotated tag object: \`${UPSTREAM_TAG_OBJECT}\`"
  echo "- Peeled upstream commit: \`${UPSTREAM_COMMIT}\`"
  echo "- Reviewed conflict evidence: run \`${FIRST_EVIDENCE_RUN_ID}\`, job \`${FIRST_EVIDENCE_JOB_ID}\`, artifact \`${FIRST_EVIDENCE_ARTIFACT_ID}\`"
  echo "- Audited staging commit: \`${setup_commit}\`"
  echo "- Integration commit: \`${merge_commit}\`"
  echo "- Merge second parent: \`${parents[2]}\`"
  echo "- Protected main remained unchanged: \`${BASE_MAIN_SHA}\`"
  echo "- Next boundary: connected-tool cleanup and exact-source selection"
} >>"$GITHUB_STEP_SUMMARY"

echo "Integrated $UPSTREAM_TAG as $merge_commit on $STAGING_BRANCH; main remains unchanged."
