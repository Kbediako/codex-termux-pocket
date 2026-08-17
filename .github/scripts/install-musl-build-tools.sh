#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
core_script="${script_dir}/install-musl-build-tools-core-49035f.sh"

# GitHub applies GITHUB_PATH entries between steps. Some workflows install Zig
# and invoke this helper in the same shell, so recover an executable Zig path
# from the command file before the shared core selects its compiler toolchain.
if ! command -v zig >/dev/null 2>&1 && [[ -f "${GITHUB_PATH:-}" ]]; then
  while IFS= read -r candidate; do
    if [[ -x "${candidate}/zig" ]]; then
      export PATH="${candidate}:${PATH}"
      break
    fi
  done <"${GITHUB_PATH}"
fi

if [[ "${TARGET:-}" == "x86_64-unknown-linux-musl" ]]; then
  command -v zig >/dev/null 2>&1 || {
    echo "Zig is required for the x86_64 musl emulator fixture" >&2
    exit 1
  }
fi

# Keep the established production aarch64 setup byte-for-byte stable while
# layering compatibility fixes around the shared helper.
bash "$core_script"

if [[ "${TARGET:-}" == "x86_64-unknown-linux-musl" ]]; then
  runner_temp="${RUNNER_TEMP:-/tmp}"
  tool_root="${runner_temp}/codex-musl-tools-${TARGET}"
  zigcc="${tool_root}/zigcc"
  libcap_version="2.75"
  libcap_root="${tool_root}/libcap-${libcap_version}"
  libcap_tarball="${libcap_root}/libcap-${libcap_version}.tar.xz"
  libcap_prefix="${libcap_root}/prefix"
  zig_source_root="${libcap_root}/src-zig"
  zig_source_dir="${zig_source_root}/libcap-${libcap_version}"

  [[ -x "$zigcc" ]] || {
    echo "x86_64 Zig C compiler wrapper is missing: $zigcc" >&2
    exit 1
  }
  [[ -f "$libcap_tarball" ]] || {
    echo "verified libcap source archive is missing: $libcap_tarball" >&2
    exit 1
  }

  # A prior GNU/BFD final link rejected native objects produced through Zig.
  # Keep x86_64 native dependencies and the staged libcap archive on the Zig
  # compiler path, but do not use Zig's cc driver for Rust executable links:
  # Zig injects its own musl CRT even when rustc supplies -nostartfiles and its
  # self-contained CRT. The dedicated final-link wrapper below uses musl GCC
  # driver semantics with LLD, preserving both sides of that boundary.
  rm -rf "$zig_source_root"
  mkdir -p "$zig_source_root"
  tar -xJf "$libcap_tarball" -C "$zig_source_root"
  make -C "${zig_source_dir}/libcap" -j"$(nproc)" \
    CC="$zigcc" \
    AR="$(command -v ar)" \
    RANLIB="$(command -v ranlib)" \
    libcap.a
  cp "${zig_source_dir}/libcap/libcap.a" "${libcap_prefix}/lib/libcap.a"

  inspect_dir="${runner_temp}/libcap-x86_64-inspect"
  rm -rf "$inspect_dir"
  mkdir -p "$inspect_dir"
  (
    cd "$inspect_dir"
    ar x "${libcap_prefix}/lib/libcap.a" cap_proc.o
  )
  file "$inspect_dir/cap_proc.o"
  readelf -h "$inspect_dir/cap_proc.o" | grep -F 'Advanced Micro Devices X86-64' >/dev/null

  cat >"${inspect_dir}/cap-smoke.c" <<'EOF_CAP'
#include <stddef.h>
#include <sys/capability.h>

int main(void) {
  cap_t caps = cap_get_proc();
  if (caps != NULL) {
    cap_free(caps);
  }
  return 0;
}
EOF_CAP
  "$zigcc" -static \
    -I"${libcap_prefix}/include" \
    "${inspect_dir}/cap-smoke.c" \
    -L"${libcap_prefix}/lib" -lcap \
    -o "${inspect_dir}/cap-smoke"
  file "$inspect_dir/cap-smoke"
  readelf -h "$inspect_dir/cap-smoke" | grep -F 'Advanced Micro Devices X86-64' >/dev/null

  if command -v x86_64-linux-musl-gcc >/dev/null 2>&1; then
    musl_linker="$(command -v x86_64-linux-musl-gcc)"
  elif command -v musl-gcc >/dev/null 2>&1; then
    musl_linker="$(command -v musl-gcc)"
  else
    echo "x86_64 musl GCC driver is unavailable after toolchain setup" >&2
    exit 1
  fi
  lld_linker="$(command -v ld.lld || true)"
  [[ -n "$lld_linker" && -x "$lld_linker" ]] || {
    echo "ld.lld is unavailable after installing lld" >&2
    exit 1
  }
  rust_linker="${script_dir}/x86_64-linux-musl-rust-linker.sh"
  [[ -x "$rust_linker" ]] || {
    echo "x86_64 Rust final-link wrapper is missing: $rust_linker" >&2
    exit 1
  }

  cargo_linker_var="CARGO_TARGET_${TARGET^^}_LINKER"
  cargo_linker_var="${cargo_linker_var//-/_}"
  {
    echo "MUSL_GCC_LINKER=${musl_linker}"
    echo "MUSL_LLD_LINKER=${lld_linker}"
    echo "${cargo_linker_var}=${rust_linker}"
  } >>"$GITHUB_ENV"

  # GitHub applies GITHUB_ENV only to later steps. Export the same selection in
  # this shell so the interop probe can exercise it immediately, before the
  # expensive workspace build and before any compiled-target cache is reused.
  export CC="$zigcc"
  export CXX="${tool_root}/zigcxx"
  export MUSL_GCC_LINKER="$musl_linker"
  export MUSL_LLD_LINKER="$lld_linker"
  export "$cargo_linker_var=$rust_linker"
  bash "${script_dir}/check-x86_64-musl-linker-interop.sh"
fi

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
