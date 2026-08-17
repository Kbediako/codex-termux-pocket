#!/usr/bin/env bash
set -euo pipefail

expected_target="x86_64-unknown-linux-musl"
if [[ "${TARGET:-${expected_target}}" != "${expected_target}" ]]; then
  echo "This linker wrapper is only valid for ${expected_target}; TARGET=${TARGET:-unset}" >&2
  exit 1
fi

musl_driver="${MUSL_GCC_LINKER:-}"
if [[ -z "${musl_driver}" ]]; then
  if command -v x86_64-linux-musl-gcc >/dev/null 2>&1; then
    musl_driver="$(command -v x86_64-linux-musl-gcc)"
  elif command -v musl-gcc >/dev/null 2>&1; then
    musl_driver="$(command -v musl-gcc)"
  else
    echo "No x86_64 musl GCC driver is available" >&2
    exit 1
  fi
fi
[[ -x "${musl_driver}" ]] || {
  echo "Configured musl GCC driver is not executable: ${musl_driver}" >&2
  exit 1
}

lld_linker="${MUSL_LLD_LINKER:-}"
if [[ -z "${lld_linker}" ]]; then
  lld_linker="$(command -v ld.lld || true)"
fi
[[ -n "${lld_linker}" && -x "${lld_linker}" ]] || {
  echo "ld.lld is required for the x86_64 musl Rust final link" >&2
  exit 1
}

# GCC's -fuse-ld=lld selects a program named ld.lld. Put the exact verified
# binary in an isolated -B directory so the driver cannot silently fall back
# to GNU/BFD when PATH or distro alternatives differ.
linker_bin_dir="${RUNNER_TEMP:-/tmp}/codex-x86_64-musl-lld-bin"
mkdir -p "${linker_bin_dir}"
ln -sfn "${lld_linker}" "${linker_bin_dir}/ld.lld"

if [[ -n "${MUSL_LINKER_TRACE:-}" ]]; then
  {
    printf 'musl_driver=%s\n' "${musl_driver}"
    printf 'lld_linker=%s\n' "${lld_linker}"
    printf 'arg=%s\n' "$@"
  } >>"${MUSL_LINKER_TRACE}"
fi

# Rust's self-contained musl target already supplies -nostartfiles,
# -nodefaultlibs and its own CRT objects. The musl GCC driver honours those
# semantics, while LLD accepts the Zig/Clang-produced native object graph.
exec env PATH="${linker_bin_dir}:${PATH}" \
  "${musl_driver}" -B"${linker_bin_dir}/" -fuse-ld=lld "$@"
