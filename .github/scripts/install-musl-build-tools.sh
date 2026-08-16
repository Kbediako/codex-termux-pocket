#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
core_script="${script_dir}/install-musl-build-tools-core-49035f.sh"

# Keep the established musl/libcap setup byte-for-byte stable while layering
# the Rusty V8 compatibility normalization at the Cargo process boundary.
bash "$core_script"

: "${GITHUB_PATH:?GITHUB_PATH environment variable is required}"
real_cargo="$(command -v cargo)"
cargo_shim_dir="${RUNNER_TEMP:-/tmp}/codex-cargo-shim"
cargo_shim="${cargo_shim_dir}/cargo"
mkdir -p "$cargo_shim_dir"
cat > "$cargo_shim" <<EOF_SHIM
#!/usr/bin/env bash
set -euo pipefail

# rusty_v8 150.4.0 opens non-HTTP RUSTY_V8_ARCHIVE values directly as local
# paths. Normalize the legacy file:// form still emitted by the workflow.
if [[ "\${RUSTY_V8_ARCHIVE:-}" == file://* ]]; then
  export RUSTY_V8_ARCHIVE="\${RUSTY_V8_ARCHIVE#file://}"
fi

exec "${real_cargo}" "\$@"
EOF_SHIM
chmod 0755 "$cargo_shim"
echo "$cargo_shim_dir" >> "$GITHUB_PATH"
