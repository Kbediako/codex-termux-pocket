#!/data/data/com.termux/files/usr/bin/bash
# Shared, source-only helpers for the Termux installer, updater, and smoke test.

CODEX_TERMUX_TARGET="aarch64-unknown-linux-musl"
CODEX_TERMUX_ARTIFACT_NAME="codex-termux-${CODEX_TERMUX_TARGET}"
CODEX_TERMUX_ARCHIVE="${CODEX_TERMUX_ARTIFACT_NAME}.tar.gz"
CODEX_TERMUX_METADATA="metadata.env"
CODEX_TERMUX_CHECKSUMS="SHA256SUMS"
CODEX_TERMUX_RUNTIME_CHECKSUMS="runtime-files.sha256"
CODEX_TERMUX_MAX_ARCHIVE_ENTRIES="${CODEX_TERMUX_MAX_ARCHIVE_ENTRIES:-4096}"
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
    if [[ "$candidate_tag" =~ ^rust-v[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+$ ]]; then
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

  [[ -f "$metadata" && -f "$checksums" && -f "$archive" ]] || {
    termux_die "artifact download is incomplete; expected $CODEX_TERMUX_ARCHIVE, $CODEX_TERMUX_METADATA, and $CODEX_TERMUX_CHECKSUMS."
    return 1
  }

  termux_validate_key_value_file "$metadata"     format_version source_repository head_sha git_describe codex_version target source_ref || {
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
  (cd "$dir" && sha256sum --check --strict "$CODEX_TERMUX_CHECKSUMS") || {
    termux_die 'artifact SHA-256 verification failed.'
    return 1
  }

  format="$(termux_metadata_value "$metadata" format_version)"
  target="$(termux_metadata_value "$metadata" target)"
  head_sha="$(termux_metadata_value "$metadata" head_sha)"
  version="$(termux_metadata_value "$metadata" codex_version)"
  source_repository="$(termux_metadata_value "$metadata" source_repository)"
  [[ "$format" == "1" || "$format" == "2" ]] || { termux_die "unsupported artifact format: ${format:-missing}"; return 1; }
  [[ "$target" == "$CODEX_TERMUX_TARGET" ]] || { termux_die "artifact target mismatch: ${target:-missing}"; return 1; }
  termux_validate_sha "$head_sha" || { termux_die 'artifact metadata has an invalid head_sha.'; return 1; }
  [[ "$head_sha" == "$expected_sha" ]] || {
    termux_die "artifact commit mismatch: expected $expected_sha, got $head_sha."
    return 1
  }
  [[ -n "$version" && "$version" != *$'\n'* ]] || { termux_die 'artifact metadata has an invalid codex_version.'; return 1; }
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
    termux_validate_sha256 "$expected_archive_sha" || { termux_die 'release manifest has an invalid archive SHA-256.'; return 1; }
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

termux_installed_metadata() {
  local prefix="${1:-$PREFIX}"
  printf '%s/libexec/codex-termux/current/metadata.env\n' "$prefix"
}
