#!/data/data/com.termux/files/usr/bin/bash
# Shared, source-only helpers for the Termux installer, updater, and smoke test.

CODEX_TERMUX_TARGET="aarch64-unknown-linux-musl"
CODEX_TERMUX_ARTIFACT_NAME="codex-termux-${CODEX_TERMUX_TARGET}"
CODEX_TERMUX_ARCHIVE="${CODEX_TERMUX_ARTIFACT_NAME}.tar.gz"
CODEX_TERMUX_METADATA="metadata.env"
CODEX_TERMUX_CHECKSUMS="SHA256SUMS"
CODEX_TERMUX_RUNTIME_CHECKSUMS="runtime-files.sha256"
CODEX_TERMUX_MAX_ARCHIVE_ENTRIES="${CODEX_TERMUX_MAX_ARCHIVE_ENTRIES:-4096}"
CODEX_TERMUX_INSTALL_SAFETY_BYTES="${CODEX_TERMUX_INSTALL_SAFETY_BYTES:-67108864}"
CODEX_TERMUX_FORK_URL_DEFAULT="https://github.com/Kbediako/codex-termux-pocket.git"
# shellcheck disable=SC2034 # Used by scripts that source this library.
CODEX_TERMUX_FORK_REPO_DEFAULT="Kbediako/codex-termux-pocket"
CODEX_TERMUX_UPSTREAM_URL="https://github.com/openai/codex.git"

termux_die() {
  printf 'codex-termux: %s\n' "$*" >&2
  return 1
}

termux_abort() {
  printf 'codex-termux: %s\n' "$*" >&2
  exit 1
}

termux_info() {
  printf 'codex-termux: %s\n' "$*"
}

termux_require_command() {
  command -v "$1" >/dev/null 2>&1 || { termux_die "required command not found: $1"; return 1; }
}

termux_is_environment() {
  [[ "${PREFIX:-}" == */com.termux/files/usr ]]
}

termux_check_environment() {
  termux_is_environment || { termux_die 'this command must run inside Termux.'; return 1; }
  if [[ "${TERMUX_APK_RELEASE:-}" == "GOOGLE_PLAY" ]]; then
    termux_die 'the legacy Google Play Termux build is unsupported; install current Termux from F-Droid or GitHub.'
    return 1
  fi
  if [[ "$(uname -m)" != "aarch64" ]]; then
    termux_die "unsupported CPU architecture $(uname -m); this bundle requires aarch64."
    return 1
  fi
}

termux_download() {
  local url="$1"
  local output="$2"
  local partial="${output}.part.$$"
  curl --fail --location --silent --show-error --retry 3 --retry-delay 2 \
    --output "$partial" "$url"
  mv -f "$partial" "$output"
}

termux_metadata_value() {
  local file="$1"
  local key="$2"
  awk -F= -v wanted="$key" '$1 == wanted { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

termux_validate_sha() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

termux_validate_sha256() {
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
    find "$root" -type f       ! -path "$root/$CODEX_TERMUX_METADATA"       ! -path "$root/$CODEX_TERMUX_CHECKSUMS"       -print0
  )
  printf '%s
' "$total"
}

termux_available_bytes() {
  local probe="$1"
  local available
  if [[ -n "${CODEX_TERMUX_AVAILABLE_BYTES:-}" ]]; then
    termux_validate_nonnegative_integer "$CODEX_TERMUX_AVAILABLE_BYTES" || {
      termux_die 'CODEX_TERMUX_AVAILABLE_BYTES must be a non-negative integer.'
      return 1
    }
    printf '%s
' "$CODEX_TERMUX_AVAILABLE_BYTES"
    return 0
  fi
  while [[ ! -e "$probe" && "$probe" != "/" ]]; do
    probe="$(dirname "$probe")"
  done
  available="$(df -Pk "$probe" | tail -n 1 | awk '{ printf "%.0f\n", $(NF-2) * 1024 }')"
  termux_validate_nonnegative_integer "$available" || {
    termux_die "cannot determine available storage for $probe"
    return 1
  }
  printf '%s
' "$available"
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

termux_validate_key_value_file() {
  local file="$1"
  shift
  local allowed=" $* "
  [[ -f "$file" ]] || return 1
  awk -F= -v allowed="$allowed" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    index($0, "\r") { exit 1 }
    $0 !~ /^[A-Za-z_][A-Za-z0-9_]*=/ { exit 1 }
    {
      key = $1
      if (index(allowed, " " key " ") == 0 || seen[key]++) { exit 1 }
    }
  ' "$file"
}

termux_validate_sha256_manifest() {
  local file="$1"
  [[ -f "$file" && ! -L "$file" ]] || return 1
  awk '
    $0 !~ /^[0-9a-f]{64} [ *][A-Za-z0-9._\/-]+$/ { exit 1 }
    {
      path = substr($0, 67)
      if (path == "" || path ~ /^\// || path ~ /(^|\/)\.\.(\/|$)/ || path ~ /\/\// || seen[path]++) {
        exit 1
      }
    }
  ' "$file"
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
  (cd "$root" && sha256sum --check --strict "$CODEX_TERMUX_RUNTIME_CHECKSUMS" >/dev/null) || {
    termux_die 'runtime file integrity verification failed.'
    return 1
  }

  expected="$(awk '{print substr($0, 67)}' "$manifest" | LC_ALL=C sort)"
  actual="$(
    cd "$root"
    find . -type f       ! -path "./$CODEX_TERMUX_RUNTIME_CHECKSUMS"       ! -path "./$CODEX_TERMUX_METADATA"       ! -path "./$CODEX_TERMUX_CHECKSUMS"       -print | sed 's#^\./##' | LC_ALL=C sort
  )"
  [[ "$actual" == "$expected" ]] || {
    termux_die 'runtime tree contains missing or unexpected files.'
    return 1
  }
}

termux_latest_valid_alpha_tag() {
  local repo_dir="$1"
  local merged_ref="${2:-}"
  local candidate_tag
  local -a tag_command=(git -C "$repo_dir" tag --list 'rust-v*-alpha.*' --sort=-version:refname)

  if [[ -n "$merged_ref" ]]; then
    tag_command=(git -C "$repo_dir" tag --merged "$merged_ref" --list 'rust-v*-alpha.*' --sort=-version:refname)
  fi
  while IFS= read -r candidate_tag; do
    if [[ "$candidate_tag" =~ ^rust-v[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+(\.[0-9]+)*$ ]]; then
      printf '%s\n' "$candidate_tag"
      return 0
    fi
  done < <("${tag_command[@]}")
  return 1
}

termux_configure_remotes() {
  local repo_dir="$1"
  local fork_url="${2:-$CODEX_TERMUX_FORK_URL_DEFAULT}"
  local origin_url=""

  [[ -d "$repo_dir/.git" ]] || { termux_die "not a Git checkout: $repo_dir"; return 1; }
  origin_url="$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)"

  if [[ -z "$origin_url" ]]; then
    git -C "$repo_dir" remote add origin "$fork_url"
  elif [[ "$origin_url" == "$CODEX_TERMUX_UPSTREAM_URL" || "$origin_url" == "${CODEX_TERMUX_UPSTREAM_URL%.git}" ]]; then
    if git -C "$repo_dir" remote get-url upstream >/dev/null 2>&1; then
      termux_die 'origin points to OpenAI but an upstream remote already exists; refusing to rewrite ambiguous remotes.'
      return 1
    fi
    git -C "$repo_dir" remote rename origin upstream
    git -C "$repo_dir" remote add origin "$fork_url"
  elif [[ "$origin_url" != "$fork_url" && "$origin_url" != "${fork_url%.git}" ]]; then
    termux_die "origin is $origin_url, not the expected Termux fork; refusing to modify this checkout."
    return 1
  fi

  if git -C "$repo_dir" remote get-url upstream >/dev/null 2>&1; then
    git -C "$repo_dir" remote set-url upstream "$CODEX_TERMUX_UPSTREAM_URL"
  else
    git -C "$repo_dir" remote add upstream "$CODEX_TERMUX_UPSTREAM_URL"
  fi
  git -C "$repo_dir" config remote.upstream.pushurl DISABLED
  git -C "$repo_dir" config remote.pushDefault origin
  git -C "$repo_dir" config branch.main.remote origin
  git -C "$repo_dir" config branch.main.merge refs/heads/main
  git -C "$repo_dir" config branch.main.pushRemote origin
}

termux_remote_repo_slug() {
  local repo_dir="$1"
  local remote_name="${2:-origin}"
  local url slug
  url="$(git -C "$repo_dir" remote get-url "$remote_name" 2>/dev/null || true)"
  case "$url" in
    https://github.com/*)
      slug="${url#https://github.com/}"
      ;;
    git@github.com:*)
      slug="${url#git@github.com:}"
      ;;
    *)
      return 1
      ;;
  esac
  printf '%s\n' "${slug%.git}"
}

termux_verify_download_set() {
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

termux_extract_and_verify_bundle() {
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

termux_write_launcher() {
  local launcher="$1"
  local prefix="$2"
  local runtime_root="$3"
  local temporary="${launcher}.new.$$"
  mkdir -p "$(dirname "$launcher")"
  cat >"$temporary" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

PREFIX_DIR="$prefix"
RUNTIME_ROOT="$runtime_root"
REAL_CODEX="\${RUNTIME_ROOT}/current/bin/codex"
RESOURCE_DIR="\${RUNTIME_ROOT}/current/codex-resources"
TERMUX_RESOLV_CONF="\${PREFIX_DIR}/etc/resolv.conf"
TERMUX_CA_BUNDLE="\${PREFIX_DIR}/etc/tls/cert.pem"
TERMUX_BROWSER="\${PREFIX_DIR}/bin/termux-open-url"
TERMUX_PROOT="\${PREFIX_DIR}/bin/proot"

[[ -x "\$REAL_CODEX" ]] || { echo "Codex runtime missing: \$REAL_CODEX" >&2; exit 1; }
[[ -x "\${RUNTIME_ROOT}/current/bin/codex-code-mode-host" ]] || { echo "Codex code-mode host missing" >&2; exit 1; }
[[ -x "\${RESOURCE_DIR}/bwrap" ]] || { echo "Bundled bubblewrap missing" >&2; exit 1; }

# Codex supports this verified bundled copy. Making it discoverable on PATH also
# prevents the generic desktop package-manager warning on Termux.
export PATH="\${RESOURCE_DIR}:\${RUNTIME_ROOT}/current/bin:\${PATH}"
if [[ -z "\${BROWSER:-}" && -x "\$TERMUX_BROWSER" ]]; then
  export BROWSER="\$TERMUX_BROWSER"
fi
if [[ -f "\$TERMUX_CA_BUNDLE" ]]; then
  export SSL_CERT_FILE="\${SSL_CERT_FILE:-\$TERMUX_CA_BUNDLE}"
  export CURL_CA_BUNDLE="\${CURL_CA_BUNDLE:-\$TERMUX_CA_BUNDLE}"
fi

if [[ "\${1:-}" == "--termux-launcher-check" ]]; then
  [[ -f "\$TERMUX_RESOLV_CONF" ]] || { echo "missing DNS config: \$TERMUX_RESOLV_CONF" >&2; exit 1; }
  [[ -f "\$TERMUX_CA_BUNDLE" ]] || { echo "missing CA bundle: \$TERMUX_CA_BUNDLE" >&2; exit 1; }
  [[ -x "\$TERMUX_PROOT" ]] || { echo "missing proot: \$TERMUX_PROOT" >&2; exit 1; }
  [[ -x "\$TERMUX_BROWSER" ]] || { echo "missing browser handoff: \$TERMUX_BROWSER" >&2; exit 1; }
  [[ "\${BROWSER:-}" == "\$TERMUX_BROWSER" ]] || { echo "browser handoff was not exported" >&2; exit 1; }
  printf 'runtime=%s\nbwrap=%s\nbrowser=%s\n' "\$REAL_CODEX" "\${RESOURCE_DIR}/bwrap" "\$TERMUX_BROWSER"
  exit 0
fi

if [[ "\${CODEX_TERMUX_DISABLE_PROOT:-0}" != "1" && -x "\$TERMUX_PROOT" \
      && -f "\$TERMUX_RESOLV_CONF" && -f "\$TERMUX_CA_BUNDLE" ]]; then
  exec "\$TERMUX_PROOT" \
    -b "\$TERMUX_RESOLV_CONF:/etc/resolv.conf" \
    -b "\$TERMUX_CA_BUNDLE:/etc/ssl/certs/ca-certificates.crt" \
    "\$REAL_CODEX" "\$@"
fi
exec "\$REAL_CODEX" "\$@"
EOF
  chmod 0755 "$temporary"
  mv -f "$temporary" "$launcher"
}

termux_installed_release_is_valid() {
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

termux_previous_release_sha() {
  local prefix="${1:-$PREFIX}"
  local runtime_root target
  runtime_root="$(termux_runtime_root "$prefix")"
  target="$(readlink "$runtime_root/previous" 2>/dev/null || true)"
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
  local runtime_root release link_tmp previous_tmp version old_current
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
  old_current="$(termux_current_release_sha "$prefix" || true)"
  mkdir -p "$runtime_root"
  if [[ -n "$old_current" && "$old_current" != "$sha" ]]     && termux_installed_release_is_valid       "$runtime_root/releases/$old_current" "$old_current"; then
    previous_tmp="$runtime_root/.previous-$$"
    rm -f "$previous_tmp"
    ln -s "releases/$old_current" "$previous_tmp"
    mv -Tf "$previous_tmp" "$runtime_root/previous"
  fi
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
  local runtime_root releases current previous record sha dir remaining=0
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
  previous="$(termux_previous_release_sha "$prefix" || true)"
  remaining=$(( 10#$keep_count ))
  if [[ -n "$current" ]]; then
    protected["$current"]=1
    remaining=$(( remaining - 1 ))
  fi
  if (( remaining > 0 )) && [[ -n "$previous" && "$previous" != "$current" ]]     && termux_installed_release_is_valid       "$releases/$previous" "$previous" >/dev/null 2>&1; then
    protected["$previous"]=1
    remaining=$(( remaining - 1 ))
  fi
  mapfile -t records < <(termux_release_records "$prefix")
  for record in "${records[@]}"; do
    sha="${record#*|}"
    [[ "$sha" == "$current" || "$sha" == "$previous" ]] && continue
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

  if [[ -n "$previous" && -z "${protected[$previous]:-}" ]]; then
    rm -f "$runtime_root/previous"
  fi

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
  local current previous record sha
  current="$(termux_current_release_sha "$prefix" || true)"
  [[ -n "$current" ]] || {
    termux_die 'cannot roll back because no active Termux release was found.'
    return 1
  }
  previous="$(termux_previous_release_sha "$prefix" || true)"
  if [[ -n "$previous" && "$previous" != "$current" ]]     && termux_installed_release_is_valid       "$(termux_runtime_root "$prefix")/releases/$previous" "$previous"; then
    termux_activate_installed_release "$prefix" "$previous"
    return 0
  fi
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

termux_installed_metadata() {
  local prefix="${1:-$PREFIX}"
  printf '%s/libexec/codex-termux/current/metadata.env\n' "$prefix"
}
