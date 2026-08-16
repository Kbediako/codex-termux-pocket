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
    updated, count = re.subn(pattern, replacement, text, count=1, flags=flags)
    if count != 1:
        raise SystemExit(f"{path}: expected one regex match, found {count}")
    target.write_text(updated, encoding="utf-8")


LIB = "scripts/termux/termux-mobile-lib.sh"
UPDATER = "scripts/termux/codex-update-alpha"
SMOKE = "scripts/termux/smoke-test-artifact"
TESTS = "scripts/termux/tests/run-tests"
WORKFLOW = ".github/workflows/termux-mobile-artifact.yml"

replace_once(
    LIB,
    'CODEX_TERMUX_CHECKSUMS="SHA256SUMS"\n',
    'CODEX_TERMUX_CHECKSUMS="SHA256SUMS"\n'
    'CODEX_TERMUX_RUNTIME_CHECKSUMS="runtime-files.sha256"\n'
    'CODEX_TERMUX_MAX_ARCHIVE_ENTRIES="${CODEX_TERMUX_MAX_ARCHIVE_ENTRIES:-4096}"\n',
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

termux_validate_key_value_file() {
  local file="$1"
  shift
  local allowed=" $* "
  [[ -f "$file" ]] || return 1
  awk -F= -v allowed="$allowed" '\n    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }\n    index($0, "\\r") { exit 1 }\n    $0 !~ /^[A-Za-z_][A-Za-z0-9_]*=/ { exit 1 }\n    {\n      key = $1\n      if (index(allowed, " " key " ") == 0 || seen[key]++) { exit 1 }\n    }\n  ' "$file"
}

termux_validate_sha256_manifest() {
  local file="$1"
  [[ -f "$file" && ! -L "$file" ]] || return 1
  awk '\n    $0 !~ /^[0-9a-f]{64} [ *][A-Za-z0-9._\\/-]+$/ { exit 1 }\n    {\n      path = substr($0, 67)\n      if (path == "" || path ~ /^\\// || path ~ /(^|\\/)\\.\\.(\\/|$)/ || path ~ /\\/\\// || seen[path]++) {\n        exit 1\n      }\n    }\n  ' "$file"
}

termux_verify_runtime_tree() {
  local root="$1"
  local manifest="$root/$CODEX_TERMUX_RUNTIME_CHECKSUMS"
  local expected actual

  [[ -d "$root" ]] || { termux_die "runtime root is missing: $root"; return 1; }
  [[ -f "$manifest" && ! -L "$manifest" ]] || {
    termux_die "runtime file manifest is missing: $CODEX_TERMUX_RUNTIME_CHECKSUMS"
    return 1
  }
  termux_validate_sha256_manifest "$manifest" || {
    termux_die 'runtime file manifest is malformed or contains an unsafe path.'
    return 1
  }
  if find "$root" -type l -print -quit | grep -q .; then
    termux_die 'runtime tree contains a symbolic link.'
    return 1
  fi
  if find "$root" ! -type f ! -type d -print -quit | grep -q .; then
    termux_die 'runtime tree contains a special filesystem entry.'
    return 1
  fi
  (cd "$root" && sha256sum --check --strict "$CODEX_TERMUX_RUNTIME_CHECKSUMS") || {
    termux_die 'runtime file integrity verification failed.'
    return 1
  }

  expected="$(awk '{print substr($0, 67)}' "$manifest" | LC_ALL=C sort)"
  actual="$(
    cd "$root"
    find . -type f \
      ! -path "./$CODEX_TERMUX_RUNTIME_CHECKSUMS" \
      ! -path "./$CODEX_TERMUX_METADATA" \
      ! -path "./$CODEX_TERMUX_CHECKSUMS" \
      -print | sed 's#^\\./##' | LC_ALL=C sort
  )"
  [[ "$actual" == "$expected" ]] || {
    termux_die 'runtime tree contains missing or unexpected files.'
    return 1
  }
}
''',
)

replace_once(
    LIB,
    '''  if grep -Eq '(^|[[:space:]])(/|\\.\\./)' "$checksums"; then
    termux_die 'checksum manifest contains an unsafe path.'
    return 1
  fi
  (cd "$dir" && sha256sum --check --strict "$CODEX_TERMUX_CHECKSUMS") || {
''',
    '''  termux_validate_key_value_file "$metadata" \
    format_version source_repository head_sha git_describe codex_version target source_ref || {
    termux_die 'artifact metadata is malformed, duplicated, or contains an unknown key.'
    return 1
  }
  termux_validate_sha256_manifest "$checksums" || {
    termux_die 'checksum manifest is malformed or contains an unsafe path.'
    return 1
  }
  local checksum_names
  checksum_names="$(awk '{print substr($0, 67)}' "$checksums" | LC_ALL=C sort)"
  [[ "$checksum_names" == "$CODEX_TERMUX_ARCHIVE"$'\\n'"$CODEX_TERMUX_METADATA" ]] || {
    termux_die 'checksum manifest does not describe exactly the archive and metadata files.'
    return 1
  }
  (cd "$dir" && sha256sum --check --strict "$CODEX_TERMUX_CHECKSUMS") || {
''',
)

replace_once(
    LIB,
    '  [[ "$format" == "1" ]] || { termux_die "unsupported artifact format: ${format:-missing}"; return 1; }\n',
    '  [[ "$format" == "1" || "$format" == "2" ]] || { termux_die "unsupported artifact format: ${format:-missing}"; return 1; }\n',
)

new_extract = r'''termux_extract_and_verify_bundle() {
  local download_dir="$1"
  local extract_dir="$2"
  local metadata="$download_dir/$CODEX_TERMUX_METADATA"
  local archive="$download_dir/$CODEX_TERMUX_ARCHIVE"
  local expected_version format entry line entry_type
  local -a entries required
  local -A seen_entries=()

  expected_version="$(termux_metadata_value "$metadata" codex_version)"
  format="$(termux_metadata_value "$metadata" format_version)"
  [[ "$CODEX_TERMUX_MAX_ARCHIVE_ENTRIES" =~ ^[0-9]+$ && "$CODEX_TERMUX_MAX_ARCHIVE_ENTRIES" -gt 0 ]] || {
    termux_die 'CODEX_TERMUX_MAX_ARCHIVE_ENTRIES must be a positive integer.'
    return 1
  }
  tar -tzf "$archive" >/dev/null || { termux_die 'runtime archive cannot be listed.'; return 1; }
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
  tar -xzf "$archive" -C "$extract_dir"
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
    [[ -f "$root/$relative" ]] || { termux_die "runtime bundle is missing $relative."; return 1; }
    [[ ! -L "$root/$relative" ]] || { termux_die "runtime bundle file must not be a symlink: $relative"; return 1; }
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
    [[ -x "$root/$relative" ]] || { termux_die "runtime file is not executable: $relative"; return 1; }
  done
  if [[ "$format" == "2" ]]; then
    termux_verify_runtime_tree "$root"
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
    new_extract + "\n",
    re.S,
)

new_install = r'''termux_installed_release_is_valid() {
  local root="$1"
  local expected_sha="$2"
  local expected_version="${3:-}"
  local metadata="$root/$CODEX_TERMUX_METADATA"
  local format installed_sha installed_version target actual_version

  [[ -f "$metadata" && ! -L "$metadata" ]] || return 1
  termux_validate_key_value_file "$metadata" \
    format_version source_repository head_sha git_describe codex_version target source_ref || return 1
  format="$(termux_metadata_value "$metadata" format_version)"
  installed_sha="$(termux_metadata_value "$metadata" head_sha)"
  installed_version="$(termux_metadata_value "$metadata" codex_version)"
  target="$(termux_metadata_value "$metadata" target)"
  [[ "$format" == "1" || "$format" == "2" ]] || return 1
  [[ "$installed_sha" == "$expected_sha" && "$target" == "$CODEX_TERMUX_TARGET" ]] || return 1
  [[ -z "$expected_version" || "$installed_version" == "$expected_version" ]] || return 1
  [[ -x "$root/bin/codex" \
    && -x "$root/bin/codex-code-mode-host" \
    && -x "$root/bin/codex-responses-api-proxy" \
    && -x "$root/codex-resources/bwrap" ]] || return 1
  if [[ "$format" == "2" ]]; then
    termux_verify_runtime_tree "$root" || return 1
  fi
  actual_version="$("$root/bin/codex" --version 2>/dev/null || true)"
  [[ -n "$installed_version" && "$installed_version" == "$actual_version" ]]
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
  local link_tmp="$runtime_root/.current-$$"
  local extracted_root

  termux_verify_download_set "$download_dir" "$expected_sha" "$expected_version" "$expected_archive_sha"
  mkdir -p "$releases"
  trap 'rm -rf "$stage" "$link_tmp"' RETURN
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

  ln -s "releases/$expected_sha" "$link_tmp"
  mv -Tf "$link_tmp" "$runtime_root/current"
  termux_write_launcher "$prefix/bin/codex" "$prefix" "$runtime_root"
  trap - RETURN
  termux_info "installed $(termux_metadata_value "$release/$CODEX_TERMUX_METADATA" codex_version) from commit $expected_sha"
}
'''
replace_regex_once(
    LIB,
    r"termux_install_verified_bundle\(\) \{.*?\n\}\n\n(?=termux_installed_metadata\(\))",
    new_install + "\n",
    re.S,
)

replace_once(UPDATER, 'temporary_dir=""\n', 'temporary_dir=""\nupdate_lock_dir=""\n')
replace_once(
    UPDATER,
    '''cleanup() {
  if [[ -n "$temporary_dir" && -d "$temporary_dir" ]]; then
    rm -rf "$temporary_dir"
  fi
}
trap cleanup EXIT INT TERM

load_release_manifest() {
''',
    '''cleanup() {
  if [[ -n "$temporary_dir" && -d "$temporary_dir" ]]; then
    rm -rf "$temporary_dir"
  fi
  if [[ -n "$update_lock_dir" && -d "$update_lock_dir" ]]; then
    rm -f "$update_lock_dir/pid"
    rmdir "$update_lock_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

acquire_update_lock() {
  local requested="${CODEX_TERMUX_LOCK_DIR:-$PREFIX/var/lock/codex-termux-update.lock}"
  mkdir -p "$(dirname "$requested")" || termux_abort "cannot create update lock parent: $(dirname "$requested")"
  if ! mkdir "$requested" 2>/dev/null; then
    local owner
    owner="$(cat "$requested/pid" 2>/dev/null || true)"
    termux_abort "another Codex Termux update is active${owner:+ (pid $owner)}; retry after it finishes."
  fi
  update_lock_dir="$requested"
  printf '%s\n' "$$" >"$update_lock_dir/pid"
}

load_release_manifest() {
''',
)
replace_once(
    UPDATER,
    '''  local format manifest_repo
  format="$(termux_metadata_value "$MANIFEST_FILE" format_version)"
  manifest_repo="$(termux_metadata_value "$MANIFEST_FILE" repository)"
  [[ "$format" == "1" ]] || termux_abort "unsupported release manifest format: ${format:-missing}"
''',
    '''  local format manifest_repo
  termux_validate_key_value_file "$MANIFEST_FILE" \
    format_version repository release_tag head_sha codex_version archive_sha256 || \
    termux_abort 'release manifest is malformed, duplicated, or contains an unknown key.'
  format="$(termux_metadata_value "$MANIFEST_FILE" format_version)"
  manifest_repo="$(termux_metadata_value "$MANIFEST_FILE" repository)"
  [[ "$format" == "1" || "$format" == "2" ]] || termux_abort "unsupported release manifest format: ${format:-missing}"
''',
)
replace_once(
    UPDATER,
    '''  [[ -n "$release_tag" && -n "$expected_sha" ]] || return 1
  termux_validate_sha "$expected_sha" || termux_abort 'release manifest contains an invalid head_sha.'
  return 0
''',
    '''  [[ "$release_tag" =~ ^termux-v[0-9A-Za-z._-]+$ ]] || termux_abort 'release manifest contains an invalid release_tag.'
  [[ -n "$release_version" && "$release_version" != *$'\\n'* ]] || termux_abort 'release manifest contains an invalid codex_version.'
  termux_validate_sha "$expected_sha" || termux_abort 'release manifest contains an invalid head_sha.'
  termux_validate_sha256 "$release_archive_sha" || termux_abort 'release manifest contains an invalid archive_sha256.'
  return 0
''',
)
replace_once(
    UPDATER,
    'termux_check_environment\nprepare_checkout\n',
    'termux_check_environment\nacquire_update_lock\nprepare_checkout\n',
)
replace_once(
    UPDATER,
    '''      installed_sha="$(termux_metadata_value "$(termux_installed_metadata)" head_sha 2>/dev/null || true)"
      if [[ "$installed_sha" == "$expected_sha" ]]; then
        termux_info "already current at $expected_sha"
        codex --version
        exit 0
      fi
''',
    '''      installed_sha="$(termux_metadata_value "$(termux_installed_metadata)" head_sha 2>/dev/null || true)"
      installed_root="$PREFIX/libexec/codex-termux/current"
      if [[ "$installed_sha" == "$expected_sha" ]] \
        && termux_installed_release_is_valid "$installed_root" "$expected_sha" "$release_version"; then
        termux_info "already current at $expected_sha"
        "$PREFIX/bin/codex" --version
        exit 0
      fi
''',
)

replace_once(
    SMOKE,
    '''  [[ ! -w "$runtime_root/bin/codex" || -O "$runtime_root/bin/codex" ]] || termux_abort 'runtime permissions/ownership are unsafe.'

  actual_version="$("$launcher" --version)"
''',
    '''  [[ ! -w "$runtime_root/bin/codex" || -O "$runtime_root/bin/codex" ]] || termux_abort 'runtime permissions/ownership are unsafe.'
  termux_installed_release_is_valid "$runtime_root" "$metadata_sha" "$metadata_version" || \
    termux_abort 'installed runtime tree failed integrity validation.'

  actual_version="$("$launcher" --version)"
''',
)

replace_once(
    TESTS,
    '''  printf '{"layoutVersion":1,"version":"%s","target":"%s"}\\n' "$version" "$CODEX_TERMUX_TARGET" >"$runtime/codex-package.json"
  tar -C "$dir" -czf "$dir/$CODEX_TERMUX_ARCHIVE" codex-termux-runtime
''',
    '''  printf '{"layoutVersion":1,"version":"%s","target":"%s"}\\n' "$version" "$CODEX_TERMUX_TARGET" >"$runtime/codex-package.json"
  (
    cd "$runtime"
    find . -type f ! -path "./$CODEX_TERMUX_RUNTIME_CHECKSUMS" -print \
      | sed 's#^\\./##' | LC_ALL=C sort \
      | while IFS= read -r relative; do sha256sum "$relative"; done \
      >"$CODEX_TERMUX_RUNTIME_CHECKSUMS"
  )
  tar -C "$dir" -czf "$dir/$CODEX_TERMUX_ARCHIVE" codex-termux-runtime
''',
)
replace_once(TESTS, 'format_version=1\nsource_repository=example/codex-termux\n', 'format_version=2\nsource_repository=example/codex-termux\n')
replace_once(
    TESTS,
    '''  termux_install_verified_bundle "$bundle" "$sha" "$version" '' "$prefix" >/dev/null
  [[ -x "$prefix/libexec/codex-termux/current/bin/codex" ]] || fail 'idempotent reinstall broke current runtime'
  pass 'complete bundle verifies and installs atomically'
''',
    '''  termux_install_verified_bundle "$bundle" "$sha" "$version" '' "$prefix" >/dev/null
  [[ -x "$prefix/libexec/codex-termux/current/bin/codex" ]] || fail 'idempotent reinstall broke current runtime'
  printf 'corruption' >>"$prefix/libexec/codex-termux/current/bin/codex-code-mode-host"
  termux_install_verified_bundle "$bundle" "$sha" "$version" '' "$prefix" >/dev/null
  ! grep -q 'corruption' "$prefix/libexec/codex-termux/current/bin/codex-code-mode-host" || \
    fail 'reinstall reused a modified installed runtime'
  compgen -G "$prefix/libexec/codex-termux/releases/${sha}.invalid.*" >/dev/null || \
    fail 'modified installed runtime was not quarantined'
  pass 'complete bundle verifies, installs atomically, and repairs modified releases'
''',
)
replace_once(
    TESTS,
    '''  pass 'artifact missing a required runtime sidecar is rejected'
}
''',
    '''  pass 'artifact missing a required runtime sidecar is rejected'

  make_bundle "$bundle" "$sha" "$version"
  bad_root="$test_root/symlink-entry"
  rm -rf "$bad_root"
  mkdir -p "$bad_root"
  tar -xzf "$bundle/$CODEX_TERMUX_ARCHIVE" -C "$bad_root"
  ln -s /etc/passwd "$bad_root/codex-termux-runtime/unexpected-link"
  tar -C "$bad_root" -czf "$bundle/$CODEX_TERMUX_ARCHIVE" codex-termux-runtime
  (cd "$bundle" && sha256sum "$CODEX_TERMUX_ARCHIVE" "$CODEX_TERMUX_METADATA" >"$CODEX_TERMUX_CHECKSUMS")
  if (termux_extract_and_verify_bundle "$bundle" "$test_root/symlink-entry-extract") >/dev/null 2>&1; then
    fail 'archive containing a symbolic link was accepted'
  fi
  pass 'archive links and special entries are rejected before activation'
}
''',
)
replace_once(
    TESTS,
    '''    CODEX_TERMUX_POLL_SECONDS=1 \\
    CODEX_TERMUX_RELEASE_MANIFEST="$manifest" \\
''',
    '''    CODEX_TERMUX_POLL_SECONDS=1 \\
    CODEX_TERMUX_LOCK_DIR="$test_root/updater.lock" \\
    CODEX_TERMUX_RELEASE_MANIFEST="$manifest" \\
''',
)
replace_once(
    TESTS,
    '''  grep -q 'sha256sum --check --strict' "$REPO_ROOT/.github/workflows/termux-mobile-artifact.yml" || fail 'workflow does not validate checksums before upload'
''',
    '''  grep -q 'sha256sum --check --strict' "$REPO_ROOT/.github/workflows/termux-mobile-artifact.yml" || fail 'workflow does not validate checksums before upload'
  grep -q 'runtime-files.sha256' "$REPO_ROOT/.github/workflows/termux-mobile-artifact.yml" || fail 'workflow does not publish a complete runtime file manifest'
  grep -q 'rusty_v8_archive_sha256' "$REPO_ROOT/.github/workflows/termux-mobile-artifact.yml" || fail 'workflow does not verify the pinned Rusty V8 archive'
  grep -q 'termux-control-plane' "$REPO_ROOT/.github/workflows/termux-control-plane.yml" || fail 'Termux control-plane workflow is missing'
''',
)

replace_once(
    WORKFLOW,
    '''            "${GITHUB_WORKSPACE}/codex-rs/rust-toolchain.toml"
            "${manifest_files[@]}"
''',
    '''            "${GITHUB_WORKSPACE}/codex-rs/rust-toolchain.toml"
            "${GITHUB_WORKSPACE}/scripts/termux/build-inputs.env"
            "${manifest_files[@]}"
''',
)

replace_regex_once(
    WORKFLOW,
    r'''      - name: Configure musl rusty_v8 artifact overrides\n.*?(?=      - name: Restore host release cache\n)''',
    '''      - name: Configure and verify musl rusty_v8 artifact overrides
        env:
          TARGET: aarch64-unknown-linux-musl
        shell: bash
        run: |
          set -euo pipefail
          lock_file="${GITHUB_WORKSPACE}/scripts/termux/build-inputs.env"
          # shellcheck disable=SC1090
          source "$lock_file"
          [[ "${format_version:-}" == "1" ]] || { echo "invalid build input lock format" >&2; exit 1; }
          version="$(python3 "${GITHUB_WORKSPACE}/.github/scripts/rusty_v8_bazel.py" resolved-v8-crate-version)"
          [[ "$version" == "$rusty_v8_version" ]] || {
            echo "Rusty V8 lock mismatch: Cargo resolves $version, lock pins $rusty_v8_version" >&2
            exit 1
          }
          base_url="https://github.com/openai/codex/releases/download/rusty-v8-v${version}"
          binding_dir="${RUNNER_TEMP}/rusty_v8"
          archive_path="${binding_dir}/librusty_v8_release_${TARGET}.a.gz"
          binding_path="${binding_dir}/src_binding_release_${TARGET}.rs"
          mkdir -p "$binding_dir"
          curl -fsSL "${base_url}/librusty_v8_release_${TARGET}.a.gz" -o "$archive_path"
          curl -fsSL "${base_url}/src_binding_release_${TARGET}.rs" -o "$binding_path"
          printf '%s  %s\\n' "$rusty_v8_archive_sha256" "$archive_path" | sha256sum --check --strict
          printf '%s  %s\\n' "$rusty_v8_binding_sha256" "$binding_path" | sha256sum --check --strict
          echo "RUSTY_V8_ARCHIVE=file://${archive_path}" >> "$GITHUB_ENV"
          echo "RUSTY_V8_SRC_BINDING_PATH=${binding_path}" >> "$GITHUB_ENV"

''',
    re.S,
)

replace_once(
    WORKFLOW,
    '''          (runtime_root / "codex-package.json").write_text(
              json.dumps(package, indent=2) + "\\n", encoding="utf-8"
          )
          metadata = "\\n".join(
''',
    '''          (runtime_root / "codex-package.json").write_text(
              json.dumps(package, indent=2) + "\\n", encoding="utf-8"
          )
          import hashlib
          manifest_lines = []
          for path in sorted(item for item in runtime_root.rglob("*") if item.is_file()):
              relative = path.relative_to(runtime_root).as_posix()
              digest = hashlib.sha256(path.read_bytes()).hexdigest()
              manifest_lines.append(f"{digest}  {relative}")
          (runtime_root / "runtime-files.sha256").write_text(
              "\\n".join(manifest_lines) + "\\n", encoding="utf-8"
          )
          metadata = "\\n".join(
''',
)
WORKFLOW_PATH = Path(WORKFLOW)
workflow_text = WORKFLOW_PATH.read_text(encoding="utf-8")
workflow_text = workflow_text.replace('"format_version=1",', '"format_version=2",')
workflow_text = workflow_text.replace('          format_version=1\n', '          format_version=2\n')
WORKFLOW_PATH.write_text(workflow_text, encoding="utf-8")
replace_once(
    WORKFLOW,
    '''          test -f "$runtime/codex-package.json"
          metadata_version="$(sed -n 's/^codex_version=//p' metadata.env)"
''',
    '''          test -f "$runtime/codex-package.json"
          test -f "$runtime/runtime-files.sha256"
          (cd "$runtime" && sha256sum --check --strict runtime-files.sha256)
          metadata_version="$(sed -n 's/^codex_version=//p' metadata.env)"
''',
)

print("Termux integrity hardening patch applied successfully.")
