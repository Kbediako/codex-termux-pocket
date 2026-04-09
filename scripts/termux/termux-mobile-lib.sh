download_file() {
  url="$1"
  output="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$output"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -q -O "$output" "$url"
    return
  fi

  echo "curl or wget is required." >&2
  exit 1
}

upstream_release_asset_url() {
  tag="$1"
  asset="$2"
  printf 'https://github.com/openai/codex/releases/download/%s/%s\n' "$tag" "$asset"
}

download_upstream_release_binary() {
  tag="$1"
  dest_dir="$2"

  archive_path="${dest_dir}/codex-aarch64-unknown-linux-musl.tar.gz"
  asset_url="$(upstream_release_asset_url "$tag" 'codex-aarch64-unknown-linux-musl.tar.gz')"

  download_file "$asset_url" "$archive_path"
  tar -xzf "$archive_path" -C "$dest_dir"
  binary_path="${dest_dir}/codex-aarch64-unknown-linux-musl"
  if [ ! -f "$binary_path" ]; then
    echo "Expected extracted binary missing: $binary_path" >&2
    exit 1
  fi
  chmod 700 "$binary_path"
  printf '%s\n' "$binary_path"
}

run_codex_smoke_checks() {
  binary_path="$1"

  "$binary_path" --version >/dev/null
  "$binary_path" --help >/dev/null
  "$binary_path" exec --help >/dev/null
  "$binary_path" completion zsh >/dev/null
}

install_codex_binary() {
  src_binary="$1"
  dest_binary="$2"
  dest_dir="$(dirname "$dest_binary")"
  tmp_binary="${dest_binary}.new.$$"

  mkdir -p "$dest_dir"
  cp "$src_binary" "$tmp_binary"
  chmod 755 "$tmp_binary"
  mv "$tmp_binary" "$dest_binary"
}

git_remote_repo_slug() {
  repo_dir="$1"
  remote_name="$2"
  remote_url="$(git -C "$repo_dir" remote get-url "$remote_name" 2>/dev/null || true)"

  case "$remote_url" in
    https://github.com/*)
      slug="${remote_url#https://github.com/}"
      slug="${slug%.git}"
      printf '%s\n' "$slug"
      return
      ;;
    git@github.com:*)
      slug="${remote_url#git@github.com:}"
      slug="${slug%.git}"
      printf '%s\n' "$slug"
      return
      ;;
  esac

  return 1
}
