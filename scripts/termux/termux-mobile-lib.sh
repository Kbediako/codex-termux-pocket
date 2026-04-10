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

codex_runtime_dir() {
  prefix_dir="$1"
  printf '%s/libexec/codex-termux\n' "$prefix_dir"
}

codex_runtime_binary_path() {
  prefix_dir="$1"
  runtime_dir="$(codex_runtime_dir "$prefix_dir")"
  printf '%s/codex\n' "$runtime_dir"
}

write_codex_wrapper() {
  dest_binary="$1"
  prefix_dir="$2"
  runtime_binary="$3"
  tmp_wrapper="${dest_binary}.new.$$"

  cat > "$tmp_wrapper" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
set -eu

PREFIX_DIR="${prefix_dir}"
RUNTIME_BINARY="${runtime_binary}"
TERMUX_RESOLV_CONF="\${PREFIX_DIR}/etc/resolv.conf"
TERMUX_CA_BUNDLE="\${PREFIX_DIR}/etc/tls/cert.pem"
TERMUX_BROWSER="\${PREFIX_DIR}/bin/termux-open-url"
TERMUX_PROOT="\${PREFIX_DIR}/bin/proot"

if [ ! -x "\$RUNTIME_BINARY" ]; then
  echo "Codex runtime missing: \$RUNTIME_BINARY" >&2
  exit 1
fi

if [ -z "\${BROWSER:-}" ] && [ -x "\$TERMUX_BROWSER" ]; then
  export BROWSER="\$TERMUX_BROWSER"
fi

if [ "\${CODEX_TERMUX_DISABLE_PROOT:-0}" != "1" ] \
  && [ -x "\$TERMUX_PROOT" ] \
  && [ -f "\$TERMUX_RESOLV_CONF" ] \
  && [ -f "\$TERMUX_CA_BUNDLE" ]; then
  exec "\$TERMUX_PROOT" \
    -b "\$TERMUX_RESOLV_CONF:/etc/resolv.conf" \
    -b "\$TERMUX_CA_BUNDLE:/etc/ssl/certs/ca-certificates.crt" \
    "\$RUNTIME_BINARY" "\$@"
fi

if [ -f "\$TERMUX_CA_BUNDLE" ]; then
  export SSL_CERT_FILE="\${SSL_CERT_FILE:-\$TERMUX_CA_BUNDLE}"
  export CURL_CA_BUNDLE="\${CURL_CA_BUNDLE:-\$TERMUX_CA_BUNDLE}"
fi

exec "\$RUNTIME_BINARY" "\$@"
EOF

  chmod 755 "$tmp_wrapper"
  mv "$tmp_wrapper" "$dest_binary"
}

install_codex_binary() {
  src_binary="$1"
  dest_binary="$2"
  prefix_dir="$(dirname "$dest_binary")"
  prefix_dir="$(dirname "$prefix_dir")"
  dest_dir="$(dirname "$dest_binary")"
  runtime_dir="$(codex_runtime_dir "$prefix_dir")"
  runtime_binary="$(codex_runtime_binary_path "$prefix_dir")"
  tmp_runtime_binary="${runtime_binary}.new.$$"

  mkdir -p "$dest_dir"
  mkdir -p "$runtime_dir"
  cp "$src_binary" "$tmp_runtime_binary"
  chmod 755 "$tmp_runtime_binary"
  mv "$tmp_runtime_binary" "$runtime_binary"
  write_codex_wrapper "$dest_binary" "$prefix_dir" "$runtime_binary"
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
