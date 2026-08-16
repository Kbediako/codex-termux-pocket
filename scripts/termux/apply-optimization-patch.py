#!/usr/bin/env python3
from __future__ import annotations

import re
from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    target = Path(path)
    text = target.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one exact match, found {count}")
    target.write_text(text.replace(old, new, 1), encoding="utf-8")


def replace_regex_once(path: str, pattern: str, replacement: str, flags: int = 0) -> None:
    target = Path(path)
    text = target.read_text(encoding="utf-8")
    updated, count = re.subn(pattern, lambda _match: replacement, text, count=1, flags=flags)
    if count != 1:
        raise SystemExit(f"{path}: expected one regex match, found {count}")
    target.write_text(updated, encoding="utf-8")


LIB = "scripts/termux/termux-mobile-lib.sh"
UPDATER = "scripts/termux/codex-update-alpha"
INSTALLER = "scripts/termux/install-codex-termux"
TESTS = "scripts/termux/tests/run-tests"
WORKFLOW = ".github/workflows/termux-mobile-artifact.yml"
CONTROL = ".github/workflows/termux-control-plane.yml"

replace_once(
    LIB,
    'CODEX_TERMUX_MAX_ARCHIVE_ENTRIES="${CODEX_TERMUX_MAX_ARCHIVE_ENTRIES:-4096}"\n',
    'CODEX_TERMUX_MAX_ARCHIVE_ENTRIES="${CODEX_TERMUX_MAX_ARCHIVE_ENTRIES:-4096}"\n'
    'CODEX_TERMUX_INSTALL_SAFETY_BYTES="${CODEX_TERMUX_INSTALL_SAFETY_BYTES:-67108864}"\n',
)

replace_once(
    LIB,
    '''termux_validate_sha256() {
  [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}
''',
    '''termux_validate_sha256() {
  [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

termux_validate_nonnegative_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

termux_validate_positive_integer() {
  termux_validate_nonnegative_integer "$1" && (( 10#$1 > 0 ))
}

termux_file_size() {
  stat -c '%s' "$1"
}

termux_runtime_payload_bytes() {
  local root="$1"
  local total=0 path size
  while IFS= read -r -d '' path; do
    size="$(termux_file_size "$path")" || return 1
    termux_validate_nonnegative_integer "$size" || return 1
    total=$(( total + 10#$size ))
  done < <(
    find "$root" -type f \
      ! -path "$root/$CODEX_TERMUX_METADATA" \
      ! -path "$root/$CODEX_TERMUX_CHECKSUMS" \
      -print0
  )
  printf '%s\n' "$total"
}

termux_available_bytes() {
  local probe="$1"
  local available
  if [[ -n "${CODEX_TERMUX_AVAILABLE_BYTES:-}" ]]; then
    termux_validate_nonnegative_integer "$CODEX_TERMUX_AVAILABLE_BYTES" || {
      termux_die 'CODEX_TERMUX_AVAILABLE_BYTES must be a non-negative integer.'
      return 1
    }
    printf '%s\n' "$CODEX_TERMUX_AVAILABLE_BYTES"
    return 0
  fi
  while [[ ! -e "$probe" && "$probe" != "/" ]]; do
    probe="$(dirname "$probe")"
  done
  available="$(df -Pk "$probe" | tail -n 1 | awk '{ printf "%.0f\\n", $(NF-2) * 1024 }')"
  termux_validate_nonnegative_integer "$available" || {
    termux_die "cannot determine available storage for $probe"
    return 1
  }
  printf '%s\n' "$available"
}

termux_require_install_space() {
  local prefix="$1"
  local archive_bytes="${2:-0}"
  local runtime_bytes="${3:-0}"
  local safety="${CODEX_TERMUX_INSTALL_SAFETY_BYTES:-67108864}"
  local available required
  termux_validate_nonnegative_integer "$archive_bytes" || {
    termux_die 'archive size must be a non-negative integer.'
    return 1
  }
  termux_validate_nonnegative_integer "$runtime_bytes" || {
    termux_die 'runtime size must be a non-negative integer.'
    return 1
  }
  termux_validate_nonnegative_integer "$safety" || {
    termux_die 'CODEX_TERMUX_INSTALL_SAFETY_BYTES must be a non-negative integer.'
    return 1
  }
  required=$(( 10#$archive_bytes + 10#$runtime_bytes + 10#$safety ))
  available="$(termux_available_bytes "$prefix")" || return 1
  if (( 10#$available < required )); then
    termux_die "insufficient storage: need at least $required bytes, available $available bytes."
    return 1
  fi
}
''',
)

verify_download = r'''termux_verify_download_set() {
  local dir="$1"
  local expected_sha="$2"
  local expected_version="${3:-}"
  local expected_archive_sha="${4:-}"
  local metadata="$dir/$CODEX_TERMUX_METADATA"
  local checksums="$dir/$CODEX_TERMUX_CHECKSUMS"
  local archive="$dir/$CODEX_TERMUX_ARCHIVE"
  local format target head_sha version archive_sha source_repository
  local archive_size runtime_size actual_archive_size

  [[ -f "$metadata" && -f "$checksums" && -f "$archive" ]] || {
    termux_die "artifact download is incomplete; expected $CODEX_TERMUX_ARCHIVE, $CODEX_TERMUX_METADATA, and $CODEX_TERMUX_CHECKSUMS."
    return 1
  }

  termux_validate_key_value_file "$metadata" \
    format_version source_repository head_sha git_describe codex_version target source_ref \
    archive_size_bytes runtime_size_bytes || {
    termux_die 'artifact metadata is malformed, duplicated, or contains an unknown key.'
    return 1
  }
  termux_validate_sha256_manifest "$checksums" || {
    termux_die 'checksum manifest is malformed or contains an unsafe path.'
    return 1
  }
  local checksum_names
  checksum_names="$(awk '{print substr($0, 67)}' "$checksums" | LC_ALL=C sort)"
  [[ "$checksum_names" == "$CODEX_TERMUX_ARCHIVE"$'\n'"$CODEX_TERMUX_METADATA" ]] || {
    termux_die 'checksum manifest does not describe exactly the archive and metadata files.'
    return 1
  }
  (cd "$dir" && sha256sum --check --strict "$CODEX_TERMUX_CHECKSUMS" >/dev/null) || {
    termux_die 'artifact SHA-256 verification failed.'
    return 1
  }

  format="$(termux_metadata_value "$metadata" format_version)"
  target="$(termux_metadata_value "$metadata" target)"
  head_sha="$(termux_metadata_value "$metadata" head_sha)"
  version="$(termux_metadata_value "$metadata" codex_version)"
  source_repository="$(termux_metadata_value "$metadata" source_repository)"
  archive_size="$(termux_metadata_value "$metadata" archive_size_bytes)"
  runtime_size="$(termux_metadata_value "$metadata" runtime_size_bytes)"
  [[ "$format" == "1" || "$format" == "2" ]] || {
    termux_die "unsupported artifact format: ${format:-missing}"
    return 1
  }
  if [[ "$format" == "2" ]]; then
    termux_validate_positive_integer "$archive_size" || {
      termux_die 'artifact metadata has an invalid archive_size_bytes.'
      return 1
    }
    termux_validate_positive_integer "$runtime_size" || {
      termux_die 'artifact metadata has an invalid runtime_size_bytes.'
      return 1
    }
    actual_archive_size="$(termux_file_size "$archive")"
    [[ "$actual_archive_size" == "$archive_size" ]] || {
      termux_die "archive size mismatch: metadata says $archive_size, file is $actual_archive_size."
      return 1
    }
  fi
  [[ "$target" == "$CODEX_TERMUX_TARGET" ]] || {
    termux_die "artifact target mismatch: ${target:-missing}"
    return 1
  }
  termux_validate_sha "$head_sha" || {
    termux_die 'artifact metadata has an invalid head_sha.'
    return 1
  }
  [[ "$head_sha" == "$expected_sha" ]] || {
    termux_die "artifact commit mismatch: expected $expected_sha, got $head_sha."
    return 1
  }
  [[ -n "$version" && "$version" != *$'\n'* ]] || {
    termux_die 'artifact metadata has an invalid codex_version.'
    return 1
  }
  [[ "$source_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
    termux_die 'artifact metadata has an invalid source_repository.'
    return 1
  }
  if [[ -n "${CODEX_TERMUX_REPO:-}" && "$source_repository" != "$CODEX_TERMUX_REPO" ]]; then
    termux_die "artifact repository mismatch: expected $CODEX_TERMUX_REPO, got $source_repository."
    return 1
  fi
  if [[ -n "$expected_version" && "$version" != "$expected_version" ]]; then
    termux_die "artifact version mismatch: expected $expected_version, got $version."
    return 1
  fi
  if [[ -n "$expected_archive_sha" ]]; then
    termux_validate_sha256 "$expected_archive_sha" || {
      termux_die 'release manifest has an invalid archive SHA-256.'
      return 1
    }
    archive_sha="$(sha256sum "$archive" | awk '{print $1}')"
    [[ "$archive_sha" == "$expected_archive_sha" ]] || {
      termux_die "archive checksum mismatch: expected $expected_archive_sha, got $archive_sha."
      return 1
    }
  fi
}
'''
replace_regex_once(
    LIB,
    r"termux_verify_download_set\(\) \{.*?\n\}\n\n(?=termux_extract_and_verify_bundle\(\))",
    verify_download + "\n",
    re.S,
)

extract_bundle = r'''termux_extract_and_verify_bundle() {
  local download_dir="$1"
  local extract_dir="$2"
  local metadata="$download_dir/$CODEX_TERMUX_METADATA"
  local archive="$download_dir/$CODEX_TERMUX_ARCHIVE"
  local expected_version format expected_runtime_size actual_runtime_size entry line entry_type
  local -a entries required
  local -A seen_entries=()

  expected_version="$(termux_metadata_value "$metadata" codex_version)"
  format="$(termux_metadata_value "$metadata" format_version)"
  expected_runtime_size="$(termux_metadata_value "$metadata" runtime_size_bytes)"
  [[ "$CODEX_TERMUX_MAX_ARCHIVE_ENTRIES" =~ ^[0-9]+$ && "$CODEX_TERMUX_MAX_ARCHIVE_ENTRIES" -gt 0 ]] || {
    termux_die 'CODEX_TERMUX_MAX_ARCHIVE_ENTRIES must be a positive integer.'
    return 1
  }
  tar -tzf "$archive" >/dev/null || {
    termux_die 'runtime archive cannot be listed.'
    return 1
  }
  mapfile -t entries < <(tar -tzf "$archive")
  (( ${#entries[@]} > 0 && ${#entries[@]} <= CODEX_TERMUX_MAX_ARCHIVE_ENTRIES )) || {
    termux_die "runtime archive has an invalid entry count: ${#entries[@]}"
    return 1
  }
  for entry in "${entries[@]}"; do
    [[ -n "$entry" \
      && "$entry" != /* \
      && "$entry" != *'\\'* \
      && "$entry" != '..' \
      && "$entry" != ../* \
      && "$entry" != *'/../'* \
      && "$entry" != *'//'* \
      && ( "$entry" == 'codex-termux-runtime' \
        || "$entry" == 'codex-termux-runtime/' \
        || "$entry" == codex-termux-runtime/* ) ]] || {
      termux_die "unsafe archive member: $entry"
      return 1
    }
    [[ -z "${seen_entries[$entry]:-}" ]] || {
      termux_die "duplicate archive member: $entry"
      return 1
    }
    seen_entries[$entry]=1
  done
  while IFS= read -r line; do
    entry_type="${line:0:1}"
    case "$entry_type" in
      -|d) ;;
      *)
        termux_die "runtime archive contains a link or special entry: $line"
        return 1
        ;;
    esac
  done < <(tar -tvzf "$archive")

  mkdir -p "$extract_dir"
  tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$extract_dir"
  local root="$extract_dir/codex-termux-runtime"
  required=(
    bin/codex
    bin/codex-code-mode-host
    bin/codex-responses-api-proxy
    codex-resources/bwrap
    codex-package.json
  )
  if [[ "$format" == "2" ]]; then
    required+=("$CODEX_TERMUX_RUNTIME_CHECKSUMS")
  fi
  local relative
  for relative in "${required[@]}"; do
    [[ -f "$root/$relative" ]] || {
      termux_die "runtime bundle is missing $relative."
      return 1
    }
    [[ ! -L "$root/$relative" ]] || {
      termux_die "runtime bundle file must not be a symlink: $relative"
      return 1
    }
  done
  if find "$root" -type l -print -quit | grep -q .; then
    termux_die 'runtime bundle contains a symbolic link.'
    return 1
  fi
  if find "$root" ! -type f ! -type d -print -quit | grep -q .; then
    termux_die 'runtime bundle contains a special filesystem entry.'
    return 1
  fi
  for relative in bin/codex bin/codex-code-mode-host bin/codex-responses-api-proxy codex-resources/bwrap; do
    [[ -x "$root/$relative" ]] || {
      termux_die "runtime file is not executable: $relative"
      return 1
    }
  done
  if [[ "$format" == "2" ]]; then
    termux_verify_runtime_tree "$root"
    actual_runtime_size="$(termux_runtime_payload_bytes "$root")" || return 1
    [[ "$actual_runtime_size" == "$expected_runtime_size" ]] || {
      termux_die "runtime size mismatch: metadata says $expected_runtime_size, extracted files total $actual_runtime_size."
      return 1
    }
  fi

  local actual_version
  actual_version="$("$root/bin/codex" --version)"
  [[ "$actual_version" == "$expected_version" ]] || {
    termux_die "binary version mismatch: metadata says $expected_version, binary says $actual_version."
    return 1
  }
  "$root/bin/codex-code-mode-host" --help >/dev/null
  "$root/bin/codex-responses-api-proxy" --help >/dev/null
  "$root/codex-resources/bwrap" --version >/dev/null
  printf '%s\n' "$root"
}
'''
replace_regex_once(
    LIB,
    r"termux_extract_and_verify_bundle\(\) \{.*?\n\}\n\n(?=termux_write_launcher\(\))",
    extract_bundle + "\n",
    re.S,
)

release_management = r'''termux_installed_release_is_valid() {
  local root="$1"
  local expected_sha="$2"
  local expected_version="${3:-}"
  local metadata="$root/$CODEX_TERMUX_METADATA"
  local format installed_sha installed_version target actual_version
  local expected_runtime_size actual_runtime_size

  [[ -f "$metadata" && ! -L "$metadata" ]] || return 1
  termux_validate_key_value_file "$metadata" \
    format_version source_repository head_sha git_describe codex_version target source_ref \
    archive_size_bytes runtime_size_bytes || return 1
  format="$(termux_metadata_value "$metadata" format_version)"
  installed_sha="$(termux_metadata_value "$metadata" head_sha)"
  installed_version="$(termux_metadata_value "$metadata" codex_version)"
  target="$(termux_metadata_value "$metadata" target)"
  expected_runtime_size="$(termux_metadata_value "$metadata" runtime_size_bytes)"
  [[ "$format" == "1" || "$format" == "2" ]] || return 1
  [[ "$installed_sha" == "$expected_sha" && "$target" == "$CODEX_TERMUX_TARGET" ]] || return 1
  [[ -z "$expected_version" || "$installed_version" == "$expected_version" ]] || return 1
  [[ -x "$root/bin/codex" \
    && -x "$root/bin/codex-code-mode-host" \
    && -x "$root/bin/codex-responses-api-proxy" \
    && -x "$root/codex-resources/bwrap" ]] || return 1
  if [[ "$format" == "2" ]]; then
    termux_validate_positive_integer "$expected_runtime_size" || return 1
    termux_verify_runtime_tree "$root" || return 1
    actual_runtime_size="$(termux_runtime_payload_bytes "$root")" || return 1
    [[ "$actual_runtime_size" == "$expected_runtime_size" ]] || return 1
  fi
  actual_version="$("$root/bin/codex" --version 2>/dev/null || true)"
  [[ -n "$installed_version" && "$installed_version" == "$actual_version" ]]
}

termux_runtime_root() {
  local prefix="${1:-$PREFIX}"
  printf '%s/libexec/codex-termux\n' "$prefix"
}

termux_current_release_sha() {
  local prefix="${1:-$PREFIX}"
  local runtime_root target
  runtime_root="$(termux_runtime_root "$prefix")"
  target="$(readlink "$runtime_root/current" 2>/dev/null || true)"
  if [[ "$target" =~ ^releases/([0-9a-f]{40})$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

termux_release_records() {
  local prefix="${1:-$PREFIX}"
  local releases dir sha mtime
  local -a records=()
  releases="$(termux_runtime_root "$prefix")/releases"
  [[ -d "$releases" ]] || return 0
  shopt -s nullglob
  for dir in "$releases"/*; do
    [[ -d "$dir" && ! -L "$dir" ]] || continue
    sha="${dir##*/}"
    termux_validate_sha "$sha" || continue
    if termux_installed_release_is_valid "$dir" "$sha" >/dev/null 2>&1; then
      mtime="$(stat -c '%Y' "$dir")"
      records+=("$mtime|$sha")
    fi
  done
  if (( ${#records[@]} > 0 )); then
    printf '%s\n' "${records[@]}" | LC_ALL=C sort -t'|' -k1,1nr -k2,2
  fi
}

termux_activate_installed_release() {
  local prefix="$1"
  local sha="$2"
  local runtime_root release link_tmp version
  termux_validate_sha "$sha" || {
    termux_die 'release activation requires a full 40-character commit SHA.'
    return 1
  }
  runtime_root="$(termux_runtime_root "$prefix")"
  release="$runtime_root/releases/$sha"
  termux_installed_release_is_valid "$release" "$sha" || {
    termux_die "installed release is missing or invalid: $sha"
    return 1
  }
  version="$(termux_metadata_value "$release/$CODEX_TERMUX_METADATA" codex_version)"
  mkdir -p "$runtime_root"
  link_tmp="$runtime_root/.current-$$"
  rm -f "$link_tmp"
  ln -s "releases/$sha" "$link_tmp"
  mv -Tf "$link_tmp" "$runtime_root/current"
  termux_write_launcher "$prefix/bin/codex" "$prefix" "$runtime_root"
  touch "$release"
  termux_info "activated $version from commit $sha"
}

termux_list_installed_releases() {
  local prefix="${1:-$PREFIX}"
  local current record sha release version found="no"
  current="$(termux_current_release_sha "$prefix" || true)"
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    sha="${record#*|}"
    release="$(termux_runtime_root "$prefix")/releases/$sha"
    version="$(termux_metadata_value "$release/$CODEX_TERMUX_METADATA" codex_version)"
    if [[ "$sha" == "$current" ]]; then
      printf '* %s  %s\n' "$sha" "$version"
    else
      printf '  %s  %s\n' "$sha" "$version"
    fi
    found="yes"
  done < <(termux_release_records "$prefix")
  [[ "$found" == "yes" ]] || {
    termux_die 'no valid installed Termux releases were found.'
    return 1
  }
}

termux_prune_installed_releases() {
  local prefix="${1:-$PREFIX}"
  local keep_count="${CODEX_TERMUX_KEEP_RELEASES:-2}"
  local quarantine_keep="${CODEX_TERMUX_KEEP_QUARANTINES:-2}"
  local runtime_root releases current record sha dir remaining=0
  local -A protected=()
  local -a records=() quarantine_records=()

  termux_validate_positive_integer "$keep_count" || {
    termux_die 'CODEX_TERMUX_KEEP_RELEASES must be a positive integer.'
    return 1
  }
  termux_validate_nonnegative_integer "$quarantine_keep" || {
    termux_die 'CODEX_TERMUX_KEEP_QUARANTINES must be a non-negative integer.'
    return 1
  }
  runtime_root="$(termux_runtime_root "$prefix")"
  releases="$runtime_root/releases"
  [[ -d "$releases" ]] || return 0
  current="$(termux_current_release_sha "$prefix" || true)"
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
    if (( remaining > 0 )); then
      protected["$sha"]=1
      remaining=$(( remaining - 1 ))
    fi
  done

  shopt -s nullglob
  for dir in "$releases"/*; do
    [[ -d "$dir" && ! -L "$dir" ]] || continue
    sha="${dir##*/}"
    termux_validate_sha "$sha" || continue
    [[ -n "${protected[$sha]:-}" ]] && continue
    if termux_installed_release_is_valid "$dir" "$sha" >/dev/null 2>&1; then
      termux_info "removing old installed runtime $sha"
      rm -rf -- "$dir"
    else
      local quarantined
      quarantined="${dir}.invalid.$(date +%s).$$"
      termux_info "quarantining invalid installed runtime $sha"
      mv "$dir" "$quarantined"
    fi
  done

  for dir in "$releases"/*.invalid.*; do
    [[ -d "$dir" && ! -L "$dir" ]] || continue
    [[ "${dir##*/}" =~ ^[0-9a-f]{40}\.invalid\.[0-9]+\.[0-9]+$ ]] || continue
    quarantine_records+=("$(stat -c '%Y' "$dir")|$dir")
  done
  if (( ${#quarantine_records[@]} > 0 )); then
    mapfile -t quarantine_records < <(
      printf '%s\n' "${quarantine_records[@]}" | LC_ALL=C sort -t'|' -k1,1nr
    )
    local index
    for (( index=10#$quarantine_keep; index<${#quarantine_records[@]}; index++ )); do
      dir="${quarantine_records[$index]#*|}"
      termux_info "removing old quarantined runtime ${dir##*/}"
      rm -rf -- "$dir"
    done
  fi
}

termux_rollback_installed_release() {
  local prefix="${1:-$PREFIX}"
  local current record sha
  current="$(termux_current_release_sha "$prefix" || true)"
  [[ -n "$current" ]] || {
    termux_die 'cannot roll back because no active Termux release was found.'
    return 1
  }
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    sha="${record#*|}"
    [[ "$sha" == "$current" ]] && continue
    termux_activate_installed_release "$prefix" "$sha"
    return 0
  done < <(termux_release_records "$prefix")
  termux_die 'no previous valid Termux release is available for rollback.'
  return 1
}

termux_install_verified_bundle() {
  local download_dir="$1"
  local expected_sha="$2"
  local expected_version="${3:-}"
  local expected_archive_sha="${4:-}"
  local prefix="${5:-$PREFIX}"
  local runtime_root="$prefix/libexec/codex-termux"
  local releases="$runtime_root/releases"
  local stage="$releases/.stage-${expected_sha}-$$"
  local release="$releases/$expected_sha"
  local extracted_root format runtime_size

  termux_verify_download_set "$download_dir" "$expected_sha" "$expected_version" "$expected_archive_sha"
  format="$(termux_metadata_value "$download_dir/$CODEX_TERMUX_METADATA" format_version)"
  if [[ "$format" == "2" ]]; then
    runtime_size="$(termux_metadata_value "$download_dir/$CODEX_TERMUX_METADATA" runtime_size_bytes)"
    termux_require_install_space "$prefix" 0 "$runtime_size"
  fi
  mkdir -p "$releases"
  trap 'rm -rf "$stage"' RETURN
  extracted_root="$(termux_extract_and_verify_bundle "$download_dir" "$stage")"
  cp "$download_dir/$CODEX_TERMUX_METADATA" "$extracted_root/$CODEX_TERMUX_METADATA"
  cp "$download_dir/$CODEX_TERMUX_CHECKSUMS" "$extracted_root/$CODEX_TERMUX_CHECKSUMS"

  if [[ -e "$release" ]]; then
    if termux_installed_release_is_valid "$release" "$expected_sha" "$expected_version"; then
      rm -rf "$stage"
    else
      local quarantined
      quarantined="${release}.invalid.$(date +%s).$$"
      termux_info "moving an invalid existing runtime aside to $quarantined"
      mv "$release" "$quarantined"
      mv "$extracted_root" "$release"
      rmdir "$stage"
    fi
  else
    mv "$extracted_root" "$release"
    rmdir "$stage"
  fi

  trap - RETURN
  termux_activate_installed_release "$prefix" "$expected_sha"
  termux_prune_installed_releases "$prefix"
}
'''
replace_regex_once(
    LIB,
    r"termux_installed_release_is_valid\(\) \{.*?\n\}\n\n(?=termux_installed_metadata\(\))",
    release_management + "\n",
    re.S,
)

replace_once(
    UPDATER,
    'release_archive_sha=""\n',
    'release_archive_sha=""\nrelease_archive_size=""\nrelease_runtime_size=""\n',
)
replace_once(
    UPDATER,
    '''  codex-update-alpha install-run --run-id ID [--expected-sha SHA]
  codex-update-alpha install-release --release-tag TAG --expected-sha SHA
''',
    '''  codex-update-alpha install-run --run-id ID [--expected-sha SHA]
  codex-update-alpha install-release --release-tag TAG --expected-sha SHA
  codex-update-alpha list-installed
  codex-update-alpha rollback
  codex-update-alpha activate --expected-sha SHA
''',
)
replace_once(
    UPDATER,
    '''  install-run    Install the complete artifact from an already-successful run.
  --dispatch     Maintainer/advanced opt-in: dispatch only when no exact matching
''',
    '''  install-run    Install the complete artifact from an already-successful run.
  list-installed Show verified installed releases; the active release is marked *.
  rollback       Atomically activate the newest previous verified release.
  activate       Atomically activate an installed verified release by commit SHA.
  --dispatch     Maintainer/advanced opt-in: dispatch only when no exact matching
''',
)
replace_once(
    UPDATER,
    '    update|check|wait|install-run|install-release)\n',
    '    update|check|wait|install-run|install-release|list-installed|rollback|activate)\n',
)
replace_regex_once(
    UPDATER,
    r'''termux_validate_key_value_file "\$MANIFEST_FILE"\s+format_version repository release_tag head_sha codex_version archive_sha256 \|\|\s+termux_abort 'release manifest is malformed, duplicated, or contains an unknown key\.' ''',
    '''termux_validate_key_value_file "$MANIFEST_FILE" \
    format_version repository release_tag head_sha codex_version archive_sha256 \
    archive_size_bytes runtime_size_bytes || \
    termux_abort 'release manifest is malformed, duplicated, or contains an unknown key.' ''',
)
replace_once(
    UPDATER,
    '''  release_archive_sha="${release_archive_sha:-$(termux_metadata_value "$MANIFEST_FILE" archive_sha256)}"
  [[ "$release_tag" =~ ^termux-v[0-9A-Za-z._-]+$ ]] || termux_abort 'release manifest contains an invalid release_tag.'
''',
    '''  release_archive_sha="${release_archive_sha:-$(termux_metadata_value "$MANIFEST_FILE" archive_sha256)}"
  release_archive_size="$(termux_metadata_value "$MANIFEST_FILE" archive_size_bytes)"
  release_runtime_size="$(termux_metadata_value "$MANIFEST_FILE" runtime_size_bytes)"
  [[ "$release_tag" =~ ^termux-v[0-9A-Za-z._-]+$ ]] || termux_abort 'release manifest contains an invalid release_tag.'
''',
)
replace_once(
    UPDATER,
    '''  termux_validate_sha256 "$release_archive_sha" || termux_abort 'release manifest contains an invalid archive_sha256.'
  return 0
''',
    '''  termux_validate_sha256 "$release_archive_sha" || termux_abort 'release manifest contains an invalid archive_sha256.'
  if [[ "$format" == "2" ]]; then
    termux_validate_positive_integer "$release_archive_size" || \
      termux_abort 'release manifest contains an invalid archive_size_bytes.'
    termux_validate_positive_integer "$release_runtime_size" || \
      termux_abort 'release manifest contains an invalid runtime_size_bytes.'
  fi
  return 0
''',
)
replace_once(
    UPDATER,
    '''  temporary_dir="$(mktemp -d)"
  termux_info "downloading maintained runtime $release_tag (commit $expected_sha)"
  termux_download "$base/$CODEX_TERMUX_ARCHIVE" "$temporary_dir/$CODEX_TERMUX_ARCHIVE"
''',
    '''  if [[ -n "$release_archive_size" && -n "$release_runtime_size" ]]; then
    termux_require_install_space "$PREFIX" "$release_archive_size" "$release_runtime_size"
  fi
  temporary_dir="$(mktemp -d)"
  termux_info "downloading maintained runtime $release_tag (commit $expected_sha)"
  termux_download "$base/$CODEX_TERMUX_ARCHIVE" "$temporary_dir/$CODEX_TERMUX_ARCHIVE"
''',
)
replace_once(UPDATER, '--limit 100 \\\n', '--limit 1000 \\\n')
replace_once(
    UPDATER,
    '''termux_check_environment
acquire_update_lock
prepare_checkout

case "$operation" in
''',
    '''termux_check_environment
case "$operation" in
  list-installed)
    termux_list_installed_releases "$PREFIX"
    exit 0
    ;;
  rollback)
    acquire_update_lock
    termux_rollback_installed_release "$PREFIX"
    "$SCRIPT_DIR/smoke-test-artifact" --installed --quick
    termux_info 'rollback complete.'
    exit 0
    ;;
  activate)
    termux_validate_sha "$expected_sha" || \
      termux_abort 'activate requires --expected-sha with a full 40-character commit SHA.'
    acquire_update_lock
    termux_activate_installed_release "$PREFIX" "$expected_sha"
    "$SCRIPT_DIR/smoke-test-artifact" --installed --quick
    termux_info 'release activation complete.'
    exit 0
    ;;
esac

acquire_update_lock
prepare_checkout

case "$operation" in
''',
)

replace_once(
    INSTALLER,
    'pkg install -y bash git curl ca-certificates coreutils tar gzip nodejs proot termux-tools ripgrep\n',
    'pkg install -y bash git curl ca-certificates coreutils findutils tar gzip nodejs proot termux-tools ripgrep\n',
)
replace_once(
    INSTALLER,
    '  git clone --origin origin --branch main --single-branch "$FORK_URL" "$INSTALL_DIR"\n',
    '  git clone --filter=blob:none --no-tags --origin origin --branch main --single-branch \\\n    "$FORK_URL" "$INSTALL_DIR"\n',
)

replace_once(
    TESTS,
    '''  tar -C "$dir" -czf "$dir/$CODEX_TERMUX_ARCHIVE" codex-termux-runtime
  rm -rf "$runtime"
  cat >"$dir/$CODEX_TERMUX_METADATA" <<EOF
''',
    '''  tar -C "$dir" -czf "$dir/$CODEX_TERMUX_ARCHIVE" codex-termux-runtime
  runtime_size_bytes="$(termux_runtime_payload_bytes "$runtime")"
  archive_size_bytes="$(termux_file_size "$dir/$CODEX_TERMUX_ARCHIVE")"
  rm -rf "$runtime"
  cat >"$dir/$CODEX_TERMUX_METADATA" <<EOF
''',
)
replace_once(
    TESTS,
    '''target=$CODEX_TERMUX_TARGET
source_ref=$sha
EOF
''',
    '''target=$CODEX_TERMUX_TARGET
source_ref=$sha
archive_size_bytes=$archive_size_bytes
runtime_size_bytes=$runtime_size_bytes
EOF
''',
)
replace_once(
    TESTS,
    '''  pass 'archive links and special entries are rejected before activation'
}
''',
    '''  pass 'archive links and special entries are rejected before activation'

  make_bundle "$bundle" "$sha" "$version"
  printf 'head_sha=%s\\n' "$sha" >>"$bundle/$CODEX_TERMUX_METADATA"
  (cd "$bundle" && sha256sum "$CODEX_TERMUX_ARCHIVE" "$CODEX_TERMUX_METADATA" >"$CODEX_TERMUX_CHECKSUMS")
  if (termux_verify_download_set "$bundle" "$sha" "$version") >/dev/null 2>&1; then
    fail 'artifact metadata containing a duplicate key was accepted'
  fi
  pass 'duplicate and unknown metadata fields are rejected'
}

make_test_bundle_for_sha() {
  local dir="$1"
  local sha="$2"
  rm -rf "$dir"
  mkdir -p "$dir"
  make_bundle "$dir" "$sha" 'codex-cli 9.9.9'
}

test_storage_retention_and_rollback() {
  local prefix="$test_root/retention-prefix"
  local bundle="$test_root/retention-bundle"
  local sha1='1111111111111111111111111111111111111111'
  local sha2='2222222222222222222222222222222222222222'
  local sha3='3333333333333333333333333333333333333333'
  mkdir -p "$prefix/bin"

  if CODEX_TERMUX_AVAILABLE_BYTES=1 CODEX_TERMUX_INSTALL_SAFETY_BYTES=0 \
      termux_require_install_space "$prefix" 1 1 >/dev/null 2>&1; then
    fail 'storage preflight accepted an undersized filesystem'
  fi
  CODEX_TERMUX_AVAILABLE_BYTES=1000000 CODEX_TERMUX_INSTALL_SAFETY_BYTES=0 \
    termux_require_install_space "$prefix" 1 1 || fail 'storage preflight rejected sufficient space'
  pass 'storage preflight rejects installs before extraction when space is insufficient'

  CODEX_TERMUX_KEEP_RELEASES=2
  CODEX_TERMUX_KEEP_QUARANTINES=1
  CODEX_TERMUX_AVAILABLE_BYTES=1000000000
  CODEX_TERMUX_INSTALL_SAFETY_BYTES=0
  make_test_bundle_for_sha "$bundle" "$sha1"
  termux_install_verified_bundle "$bundle" "$sha1" 'codex-cli 9.9.9' '' "$prefix" >/dev/null
  make_test_bundle_for_sha "$bundle" "$sha2"
  termux_install_verified_bundle "$bundle" "$sha2" 'codex-cli 9.9.9' '' "$prefix" >/dev/null
  make_test_bundle_for_sha "$bundle" "$sha3"
  termux_install_verified_bundle "$bundle" "$sha3" 'codex-cli 9.9.9' '' "$prefix" >/dev/null

  [[ ! -e "$prefix/libexec/codex-termux/releases/$sha1" ]] || fail 'retention kept more releases than configured'
  assert_eq "releases/$sha3" "$(readlink "$prefix/libexec/codex-termux/current")" 'newest release activation'
  termux_rollback_installed_release "$prefix" >/dev/null
  assert_eq "releases/$sha2" "$(readlink "$prefix/libexec/codex-termux/current")" 'rollback activation'
  termux_list_installed_releases "$prefix" | grep -q "^\\* $sha2" || fail 'release listing did not mark the active rollback target'
  pass 'bounded release retention preserves one verified rollback and activates it atomically'
}
''',
)
replace_once(
    TESTS,
    '''  grep -Eq 'pkg install .* nodejs([[:space:]]|$)' "$TERMUX_DIR/install-codex-termux" || fail 'installer does not install Node.js for plugin MCP servers'
''',
    '''  grep -Eq 'pkg install .* nodejs([[:space:]]|$)' "$TERMUX_DIR/install-codex-termux" || fail 'installer does not install Node.js for plugin MCP servers'
  grep -q -- '--filter=blob:none' "$TERMUX_DIR/install-codex-termux" || fail 'installer does not use a filtered helper checkout'
''',
)
replace_once(
    TESTS,
    '''  grep -q 'termux-control-plane' "$REPO_ROOT/.github/workflows/termux-control-plane.yml" || fail 'Termux control-plane workflow is missing'
''',
    '''  grep -q 'termux-control-plane' "$REPO_ROOT/.github/workflows/termux-control-plane.yml" || fail 'Termux control-plane workflow is missing'
  grep -q 'gzip -n -9' "$REPO_ROOT/.github/workflows/termux-mobile-artifact.yml" || fail 'runtime archive is not deterministic'
  grep -q 'actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6' "$REPO_ROOT/.github/workflows/termux-mobile-artifact.yml" || fail 'runtime provenance action is not pinned'
  grep -q 'generate-sbom.py' "$REPO_ROOT/.github/workflows/termux-mobile-artifact.yml" || fail 'runtime SBOM generation is missing'
  grep -q 'rollback)' "$TERMUX_DIR/codex-update-alpha" || fail 'updater does not expose rollback'
''',
)
replace_once(
    TESTS,
    '''test_run_dedup_and_timeout
test_static_architecture_guards
''',
    '''test_run_dedup_and_timeout
test_storage_retention_and_rollback
test_static_architecture_guards
''',
)

replace_once(
    WORKFLOW,
    '''    permissions:
      contents: read
''',
    '''    permissions:
      contents: read
      id-token: write
      attestations: write
      artifact-metadata: write
''',
)
workflow_path = Path(WORKFLOW)
workflow_text = workflow_path.read_text(encoding="utf-8")
workflow_text = workflow_text.replace(
    "uses: actions/checkout@v6",
    "uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2",
)
workflow_text = workflow_text.replace(
    "uses: actions/upload-artifact@v7",
    "uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7",
)
workflow_text = workflow_text.replace(
    "uses: actions/download-artifact@v7",
    "uses: actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131 # v7",
)
workflow_path.write_text(workflow_text, encoding="utf-8")
replace_once(
    WORKFLOW,
    '''    outputs:
      head_sha: ${{ steps.stage.outputs.head_sha }}
      codex_version: ${{ steps.stage.outputs.codex_version }}
      archive_sha256: ${{ steps.stage.outputs.archive_sha256 }}
''',
    '''    outputs:
      head_sha: ${{ steps.stage.outputs.head_sha }}
      codex_version: ${{ steps.stage.outputs.codex_version }}
      archive_sha256: ${{ steps.stage.outputs.archive_sha256 }}
      archive_size_bytes: ${{ steps.stage.outputs.archive_size_bytes }}
      runtime_size_bytes: ${{ steps.stage.outputs.runtime_size_bytes }}
''',
)
replace_once(
    WORKFLOW,
    '''            "${GITHUB_WORKSPACE}/scripts/termux/build-inputs.env"
            "${manifest_files[@]}"
''',
    '''            "${GITHUB_WORKSPACE}/scripts/termux/build-inputs.env"
            "${GITHUB_WORKSPACE}/scripts/termux/generate-sbom.py"
            "${manifest_files[@]}"
''',
)
replace_once(
    WORKFLOW,
    '''          for binary in codex codex-code-mode-host codex-responses-api-proxy; do
            cp "target/${TARGET}/release/${binary}" "${runtime_root}/bin/${binary}"
            chmod 0755 "${runtime_root}/bin/${binary}"
          done
''',
    '''          for binary in codex codex-code-mode-host codex-responses-api-proxy; do
            cp "target/${TARGET}/release/${binary}" "${runtime_root}/bin/${binary}"
            strip --strip-debug --strip-unneeded "${runtime_root}/bin/${binary}"
            chmod 0755 "${runtime_root}/bin/${binary}"
          done
''',
)
replace_once(
    WORKFLOW,
    '''          archive="${artifact_root}/codex-termux-aarch64-unknown-linux-musl.tar.gz"
          tar -C "${artifact_root}" -czf "$archive" codex-termux-runtime
          (
            cd "${artifact_root}"
            sha256sum codex-termux-aarch64-unknown-linux-musl.tar.gz metadata.env > SHA256SUMS
          )
          head_sha="$(git rev-parse HEAD)"
          codex_version="$("${runtime_root}/bin/codex" --version)"
          archive_sha256="$(sha256sum "$archive" | awk '{print $1}')"
          echo "head_sha=${head_sha}" >> "$GITHUB_OUTPUT"
          echo "codex_version=${codex_version}" >> "$GITHUB_OUTPUT"
          echo "archive_sha256=${archive_sha256}" >> "$GITHUB_OUTPUT"
''',
    '''          head_sha="$(git rev-parse HEAD)"
          codex_version="$("${runtime_root}/bin/codex" --version)"
          sbom="${artifact_root}/codex-termux-sbom.spdx.json"
          python3 "${GITHUB_WORKSPACE}/scripts/termux/generate-sbom.py" \
            --workspace "${GITHUB_WORKSPACE}/codex-rs" \
            --output "$sbom" \
            --artifact-version "$codex_version" \
            --commit "$head_sha" \
            --repository "$GITHUB_REPOSITORY"

          archive="${artifact_root}/codex-termux-aarch64-unknown-linux-musl.tar.gz"
          source_date_epoch="$(git show -s --format=%ct HEAD)"
          tar --sort=name \
            --mtime="@${source_date_epoch}" \
            --owner=0 --group=0 --numeric-owner \
            -C "${artifact_root}" -cf - codex-termux-runtime \
            | gzip -n -9 >"$archive"
          runtime_size_bytes="$(
            find "$runtime_root" -type f -printf '%s\\n' \
              | awk '{ total += $1 } END { printf "%.0f\\n", total }'
          )"
          archive_size_bytes="$(stat -c '%s' "$archive")"
          cat >>"${artifact_root}/metadata.env" <<EOF
          archive_size_bytes=${archive_size_bytes}
          runtime_size_bytes=${runtime_size_bytes}
          EOF
          (
            cd "${artifact_root}"
            sha256sum codex-termux-aarch64-unknown-linux-musl.tar.gz metadata.env > SHA256SUMS
          )
          archive_sha256="$(sha256sum "$archive" | awk '{print $1}')"
          echo "head_sha=${head_sha}" >> "$GITHUB_OUTPUT"
          echo "codex_version=${codex_version}" >> "$GITHUB_OUTPUT"
          echo "archive_sha256=${archive_sha256}" >> "$GITHUB_OUTPUT"
          echo "archive_size_bytes=${archive_size_bytes}" >> "$GITHUB_OUTPUT"
          echo "runtime_size_bytes=${runtime_size_bytes}" >> "$GITHUB_OUTPUT"
          {
            echo '### Termux runtime size'
            echo
            echo "- Compressed archive: ${archive_size_bytes} bytes"
            echo "- Installed runtime payload: ${runtime_size_bytes} bytes"
            echo "- SPDX SBOM: $(stat -c '%s' "$sbom") bytes"
          } >>"$GITHUB_STEP_SUMMARY"
''',
)
replace_once(
    WORKFLOW,
    '''          test -f "$runtime/runtime-files.sha256"
          (cd "$runtime" && sha256sum --check --strict runtime-files.sha256)
          metadata_version="$(sed -n 's/^codex_version=//p' metadata.env)"
''',
    '''          test -f "$runtime/runtime-files.sha256"
          test -f "$artifact_root/codex-termux-sbom.spdx.json"
          python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' \
            "$artifact_root/codex-termux-sbom.spdx.json"
          (cd "$runtime" && sha256sum --check --strict runtime-files.sha256)
          metadata_version="$(sed -n 's/^codex_version=//p' metadata.env)"
          metadata_archive_size="$(sed -n 's/^archive_size_bytes=//p' metadata.env)"
          metadata_runtime_size="$(sed -n 's/^runtime_size_bytes=//p' metadata.env)"
          test "$metadata_archive_size" = "$(stat -c '%s' codex-termux-aarch64-unknown-linux-musl.tar.gz)"
          actual_runtime_size="$(find "$runtime" -type f -printf '%s\\n' | awk '{ total += $1 } END { printf "%.0f\\n", total }')"
          test "$metadata_runtime_size" = "$actual_runtime_size"
''',
)
replace_once(
    WORKFLOW,
    '''      - name: Upload Termux artifact
''',
    '''      - name: Attest Termux runtime build provenance
        if: ${{ github.event_name == 'workflow_dispatch' }}
        uses: actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6 # v4.2.2
        with:
          subject-path: |
            dist/termux-mobile/codex-termux-aarch64-unknown-linux-musl.tar.gz
            dist/termux-mobile/metadata.env
            dist/termux-mobile/SHA256SUMS
            dist/termux-mobile/codex-termux-sbom.spdx.json

      - name: Attest Termux runtime SPDX SBOM
        if: ${{ github.event_name == 'workflow_dispatch' }}
        uses: actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6 # v4.2.2
        with:
          subject-path: dist/termux-mobile/codex-termux-aarch64-unknown-linux-musl.tar.gz
          sbom-path: dist/termux-mobile/codex-termux-sbom.spdx.json

      - name: Upload Termux artifact
''',
)
replace_once(
    WORKFLOW,
    '''            dist/termux-mobile/SHA256SUMS
          if-no-files-found: error
''',
    '''            dist/termux-mobile/SHA256SUMS
            dist/termux-mobile/codex-termux-sbom.spdx.json
          if-no-files-found: error
''',
)
replace_once(
    WORKFLOW,
    '''    runs-on: ubuntu-24.04
    permissions:
      contents: write
''',
    '''    runs-on: ubuntu-24.04
    environment: termux-release
    permissions:
      contents: write
''',
)
replace_once(
    WORKFLOW,
    '''          ARCHIVE_SHA256: ${{ needs.build-termux-artifact.outputs.archive_sha256 }}
''',
    '''          ARCHIVE_SHA256: ${{ needs.build-termux-artifact.outputs.archive_sha256 }}
          ARCHIVE_SIZE_BYTES: ${{ needs.build-termux-artifact.outputs.archive_size_bytes }}
          RUNTIME_SIZE_BYTES: ${{ needs.build-termux-artifact.outputs.runtime_size_bytes }}
''',
)
replace_once(
    WORKFLOW,
    '''          archive_sha256=${ARCHIVE_SHA256}
          EOF
''',
    '''          archive_sha256=${ARCHIVE_SHA256}
          archive_size_bytes=${ARCHIVE_SIZE_BYTES}
          runtime_size_bytes=${RUNTIME_SIZE_BYTES}
          EOF
''',
)
replace_once(
    WORKFLOW,
    '''            dist/SHA256SUMS \
            dist/release-manifest.env
''',
    '''            dist/SHA256SUMS \
            dist/codex-termux-sbom.spdx.json \
            dist/release-manifest.env
''',
)

replace_once(
    CONTROL,
    '''      - name: Validate shell syntax
        shell: bash
        run: |
''',
    '''      - name: Validate Python utilities
        shell: bash
        run: python3 -m py_compile scripts/termux/generate-sbom.py

      - name: Validate shell syntax
        shell: bash
        run: |
''',
)

print("Termux release optimisation patch applied successfully.")
