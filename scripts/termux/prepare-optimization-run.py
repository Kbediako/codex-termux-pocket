#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UPDATER = ROOT / "scripts/termux/codex-update-alpha"
PATCHER = ROOT / "scripts/termux/apply-optimization-patch.py"
LIB = ROOT / "scripts/termux/termux-mobile-lib.sh"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one exact match, found {count}")
    return text.replace(old, new, 1)


def prepare_legacy_inputs() -> None:
    updater_lines = UPDATER.read_text(encoding="utf-8").splitlines(keepends=True)
    matches = [
        index
        for index, line in enumerate(updater_lines)
        if 'termux_validate_key_value_file "$MANIFEST_FILE"' in line
    ]
    if len(matches) != 1:
        raise SystemExit(
            f"expected one release-manifest validation line, found {len(matches)}"
        )
    index = matches[0]
    if not updater_lines[index].endswith("\n"):
        raise SystemExit("release-manifest validation line has no newline")
    updater_lines[index] = updater_lines[index][:-1] + " \n"
    UPDATER.write_text("".join(updater_lines), encoding="utf-8")

    patch_lines = PATCHER.read_text(encoding="utf-8").splitlines(keepends=True)
    continuation_lines = [
        index
        for index, line in enumerate(patch_lines)
        if "'''            dist/SHA256SUMS" in line
    ]
    if len(continuation_lines) != 2:
        raise SystemExit(
            f"expected two release-asset template literals, found {len(continuation_lines)}"
        )
    for index in continuation_lines:
        if "r'''" in patch_lines[index]:
            raise SystemExit("release-asset template was already converted to a raw literal")
        patch_lines[index] = patch_lines[index].replace("'''", "r'''", 1)
    PATCHER.write_text("".join(patch_lines), encoding="utf-8")


def patch_explicit_rollback_history() -> None:
    text = LIB.read_text(encoding="utf-8")

    text = replace_once(
        text,
        '''termux_current_release_sha() {
  local prefix="${1:-$PREFIX}"
  local runtime_root target
  runtime_root="$(termux_runtime_root "$prefix")"
  target="$(readlink "$runtime_root/current" 2>/dev/null || true)"
  if [[ "$target" =~ ^releases/([0-9a-f]{40})$ ]]; then
    printf '%s\\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

''',
        '''termux_current_release_sha() {
  local prefix="${1:-$PREFIX}"
  local runtime_root target
  runtime_root="$(termux_runtime_root "$prefix")"
  target="$(readlink "$runtime_root/current" 2>/dev/null || true)"
  if [[ "$target" =~ ^releases/([0-9a-f]{40})$ ]]; then
    printf '%s\\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

termux_previous_release_sha() {
  local prefix="${1:-$PREFIX}"
  local runtime_root target
  runtime_root="$(termux_runtime_root "$prefix")"
  target="$(readlink "$runtime_root/previous" 2>/dev/null || true)"
  if [[ "$target" =~ ^releases/([0-9a-f]{40})$ ]]; then
    printf '%s\\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

''',
        "add previous-release parser",
    )

    text = replace_once(
        text,
        '  local runtime_root release link_tmp version\n',
        '  local runtime_root release link_tmp previous_tmp version old_current\n',
        "extend activation locals",
    )
    text = replace_once(
        text,
        '''  version="$(termux_metadata_value "$release/$CODEX_TERMUX_METADATA" codex_version)"
  mkdir -p "$runtime_root"
  link_tmp="$runtime_root/.current-$$"
''',
        '''  version="$(termux_metadata_value "$release/$CODEX_TERMUX_METADATA" codex_version)"
  old_current="$(termux_current_release_sha "$prefix" || true)"
  mkdir -p "$runtime_root"
  if [[ -n "$old_current" && "$old_current" != "$sha" ]] \
    && termux_installed_release_is_valid \
      "$runtime_root/releases/$old_current" "$old_current"; then
    previous_tmp="$runtime_root/.previous-$$"
    rm -f "$previous_tmp"
    ln -s "releases/$old_current" "$previous_tmp"
    mv -Tf "$previous_tmp" "$runtime_root/previous"
  fi
  link_tmp="$runtime_root/.current-$$"
''',
        "persist previous activation",
    )

    text = replace_once(
        text,
        '  local runtime_root releases current record sha dir remaining=0\n',
        '  local runtime_root releases current previous record sha dir remaining=0\n',
        "extend pruning locals",
    )
    text = replace_once(
        text,
        '''  current="$(termux_current_release_sha "$prefix" || true)"
  if [[ -n "$current" ]]; then
    protected["$current"]=1
    remaining=$(( 10#$keep_count - 1 ))
  else
    remaining=$(( 10#$keep_count ))
  fi
  mapfile -t records < <(termux_release_records "$prefix")
  for record in "${records[@]}"; do
    sha="${record#*|}"
    [[ "$sha" == "$current" ]] && continue
''',
        '''  current="$(termux_current_release_sha "$prefix" || true)"
  previous="$(termux_previous_release_sha "$prefix" || true)"
  remaining=$(( 10#$keep_count ))
  if [[ -n "$current" ]]; then
    protected["$current"]=1
    remaining=$(( remaining - 1 ))
  fi
  if (( remaining > 0 )) && [[ -n "$previous" && "$previous" != "$current" ]] \
    && termux_installed_release_is_valid \
      "$releases/$previous" "$previous" >/dev/null 2>&1; then
    protected["$previous"]=1
    remaining=$(( remaining - 1 ))
  fi
  mapfile -t records < <(termux_release_records "$prefix")
  for record in "${records[@]}"; do
    sha="${record#*|}"
    [[ "$sha" == "$current" || "$sha" == "$previous" ]] && continue
''',
        "protect explicit rollback release",
    )
    text = replace_once(
        text,
        '  for dir in "$releases"/*.invalid.*; do\n',
        '''  if [[ -n "$previous" && -z "${protected[$previous]:-}" ]]; then
    rm -f "$runtime_root/previous"
  fi

  for dir in "$releases"/*.invalid.*; do
''',
        "drop stale previous link",
    )

    text = replace_once(
        text,
        '''  local current record sha
  current="$(termux_current_release_sha "$prefix" || true)"
''',
        '''  local current previous record sha
  current="$(termux_current_release_sha "$prefix" || true)"
''',
        "extend rollback locals",
    )
    text = replace_once(
        text,
        '''  [[ -n "$current" ]] || {
    termux_die 'cannot roll back because no active Termux release was found.'
    return 1
  }
  while IFS= read -r record; do
''',
        '''  [[ -n "$current" ]] || {
    termux_die 'cannot roll back because no active Termux release was found.'
    return 1
  }
  previous="$(termux_previous_release_sha "$prefix" || true)"
  if [[ -n "$previous" && "$previous" != "$current" ]] \
    && termux_installed_release_is_valid \
      "$(termux_runtime_root "$prefix")/releases/$previous" "$previous"; then
    termux_activate_installed_release "$prefix" "$previous"
    return 0
  fi
  while IFS= read -r record; do
''',
        "prefer explicit rollback release",
    )

    LIB.write_text(text, encoding="utf-8")


def main() -> int:
    prepare_legacy_inputs()
    subprocess.run([sys.executable, str(PATCHER)], cwd=ROOT, check=True)
    patch_explicit_rollback_history()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
