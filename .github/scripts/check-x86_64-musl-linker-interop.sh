#!/usr/bin/env bash
set -euo pipefail

expected_target="x86_64-unknown-linux-musl"
: "${TARGET:=${expected_target}}"
[[ "${TARGET}" == "${expected_target}" ]] || {
  echo "Unexpected target for x86_64 linker preflight: ${TARGET}" >&2
  exit 1
}
: "${CC:?CC must point at the native Zig C compiler wrapper}"

cargo_linker_var="CARGO_TARGET_${TARGET^^}_LINKER"
cargo_linker_var="${cargo_linker_var//-/_}"
final_linker="${!cargo_linker_var:-}"
[[ -n "${final_linker}" && -x "${final_linker}" ]] || {
  echo "Configured Rust final linker is missing or not executable: ${final_linker:-unset}" >&2
  exit 1
}
[[ "${final_linker}" != "${CC}" ]] || {
  echo "Native dependency compiler and Rust final linker must remain separate" >&2
  exit 1
}

musl_driver="${MUSL_GCC_LINKER:-}"
[[ -n "${musl_driver}" && -x "${musl_driver}" ]] || {
  echo "MUSL_GCC_LINKER is missing or not executable: ${musl_driver:-unset}" >&2
  exit 1
}
lld_linker="${MUSL_LLD_LINKER:-$(command -v ld.lld || true)}"
[[ -n "${lld_linker}" && -x "${lld_linker}" ]] || {
  echo "MUSL_LLD_LINKER is missing or not executable: ${lld_linker:-unset}" >&2
  exit 1
}

ar_bin="${AR:-$(command -v ar || true)}"
ranlib_bin="${RANLIB:-$(command -v ranlib || true)}"
[[ -n "${ar_bin}" && -x "${ar_bin}" ]] || {
  echo "Archive tool is unavailable" >&2
  exit 1
}
[[ -n "${ranlib_bin}" && -x "${ranlib_bin}" ]] || {
  echo "ranlib is unavailable" >&2
  exit 1
}
command -v cargo >/dev/null 2>&1
command -v rustc >/dev/null 2>&1
command -v file >/dev/null 2>&1
command -v readelf >/dev/null 2>&1

printf 'target=%s\n' "${TARGET}"
printf 'cc=%s\n' "${CC}"
printf 'cxx=%s\n' "${CXX:-unset}"
printf 'archive_tool=%s\n' "${ar_bin}"
printf 'ranlib=%s\n' "${ranlib_bin}"
printf 'rust_final_linker=%s\n' "${final_linker}"
printf 'musl_gcc_driver=%s\n' "${musl_driver}"
printf 'lld=%s\n' "${lld_linker}"
"${CC}" --version | sed -n '1,2p'
"${musl_driver}" --version | sed -n '1,2p'
"${lld_linker}" --version | sed -n '1p'
if command -v zig >/dev/null 2>&1; then
  printf 'zig_version=%s\n' "$(zig version)"
fi
rustc --version --verbose
cargo --version

probe_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/codex-musl-link-preflight.XXXXXX")"
cleanup() {
  rm -rf "${probe_root}"
}
trap cleanup EXIT INT TERM

cat >"${probe_root}/native_probe.c" <<'EOF_C'
int codex_termux_link_probe(int value) {
  return value + 7;
}
EOF_C
"${CC}" -O2 -fPIC -c "${probe_root}/native_probe.c" -o "${probe_root}/native_probe.o"
file "${probe_root}/native_probe.o"
readelf -hW "${probe_root}/native_probe.o" |
  grep -F 'Advanced Micro Devices X86-64' >/dev/null
"${ar_bin}" crs "${probe_root}/libtermux_link_probe.a" "${probe_root}/native_probe.o"
"${ranlib_bin}" "${probe_root}/libtermux_link_probe.a"

mkdir -p "${probe_root}/crate/src"
cat >"${probe_root}/crate/Cargo.toml" <<'EOF_CARGO'
[package]
name = "termux-musl-linker-preflight"
version = "0.0.0"
edition = "2021"
publish = false

[profile.release]
lto = false
codegen-units = 1
EOF_CARGO
cat >"${probe_root}/crate/build.rs" <<'EOF_BUILD'
fn main() {
    let native_dir = std::env::var("TERMUX_LINK_PROBE_DIR")
        .expect("TERMUX_LINK_PROBE_DIR must be set");
    println!("cargo:rustc-link-search=native={native_dir}");
    println!("cargo:rustc-link-lib=static=termux_link_probe");
    println!("cargo:rerun-if-env-changed=TERMUX_LINK_PROBE_DIR");
}
EOF_BUILD
cat >"${probe_root}/crate/src/main.rs" <<'EOF_RUST'
extern "C" {
    fn codex_termux_link_probe(value: i32) -> i32;
}

fn main() {
    let actual = unsafe { codex_termux_link_probe(35) };
    assert_eq!(actual, 42);
}
EOF_RUST

trace_file="${probe_root}/linker.trace"
TERMUX_LINK_PROBE_DIR="${probe_root}" \
MUSL_LINKER_TRACE="${trace_file}" \
CARGO_TARGET_DIR="${probe_root}/target" \
  cargo build \
    --manifest-path "${probe_root}/crate/Cargo.toml" \
    --target "${TARGET}" \
    --release \
    --offline \
    --verbose

binary="${probe_root}/target/${TARGET}/release/termux-musl-linker-preflight"
test -x "${binary}"
test -s "${trace_file}"
grep -F "musl_driver=${musl_driver}" "${trace_file}" >/dev/null
grep -F "lld_linker=${lld_linker}" "${trace_file}" >/dev/null
grep -F 'arg=-nostartfiles' "${trace_file}" >/dev/null
grep -E '/self-contained/(rcrt1|crt1|Scrt1)\.o' "${trace_file}" >/dev/null

file_output="$(file "${binary}")"
printf '%s\n' "${file_output}"
grep -F 'ELF 64-bit' <<<"${file_output}" >/dev/null
grep -F 'x86-64' <<<"${file_output}" >/dev/null
grep -Eq 'statically linked|static-pie linked' <<<"${file_output}"
readelf -hW "${binary}" | grep -F 'Advanced Micro Devices X86-64' >/dev/null
readelf -lW "${binary}" >"${probe_root}/program-headers.txt"
if grep -Eq 'INTERP|Requesting program interpreter' "${probe_root}/program-headers.txt"; then
  echo "Unexpected dynamic interpreter in musl preflight binary" >&2
  cat "${probe_root}/program-headers.txt" >&2
  exit 1
fi
readelf -dW "${binary}" >"${probe_root}/dynamic-section.txt" 2>/dev/null || true
if grep -q '(NEEDED)' "${probe_root}/dynamic-section.txt"; then
  echo "Unexpected dynamic dependency in musl preflight binary" >&2
  cat "${probe_root}/dynamic-section.txt" >&2
  exit 1
fi
"${binary}"

echo "x86_64 Zig-object + musl-GCC/LLD Rust-link preflight passed"
