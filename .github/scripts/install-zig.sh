#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_PATH:?GITHUB_PATH environment variable is required}"

zig_version="${ZIG_VERSION:-0.14.0}"
runner_temp="${RUNNER_TEMP:-/tmp}"

case "$(uname -s):$(uname -m)" in
  Linux:x86_64)
    zig_platform="x86_64-linux"
    ;;
  Linux:aarch64|Linux:arm64)
    zig_platform="aarch64-linux"
    ;;
  *)
    echo "Unsupported runner platform for Zig install: $(uname -s):$(uname -m)" >&2
    exit 1
    ;;
esac

readarray -t zig_meta < <(
  python3 - <<'PY' "${zig_version}" "${zig_platform}"
import json
import sys
import urllib.request

version = sys.argv[1]
platform = sys.argv[2]

with urllib.request.urlopen("https://ziglang.org/download/index.json") as response:
    data = json.load(response)

entry = data[version][platform]
print(entry["tarball"])
print(entry["shasum"])
PY
)

if [[ "${#zig_meta[@]}" -ne 2 ]]; then
  echo "Failed to resolve Zig download metadata for ${zig_version} ${zig_platform}" >&2
  exit 1
fi

zig_url="${zig_meta[0]}"
zig_sha256="${zig_meta[1]}"
zig_basename="$(basename "${zig_url}")"
zig_root_dir="${zig_basename%.tar.xz}"
install_root="${runner_temp}/${zig_root_dir}"

if [[ ! -x "${install_root}/zig" ]]; then
  tmp_dir="$(mktemp -d "${runner_temp}/zig-download.XXXXXX")"
  trap 'rm -rf "${tmp_dir}"' EXIT
  tarball="${tmp_dir}/${zig_basename}"

  curl -fsSL "${zig_url}" -o "${tarball}"
  printf '%s  %s\n' "${zig_sha256}" "${tarball}" | sha256sum -c -
  tar -xJf "${tarball}" -C "${tmp_dir}"

  rm -rf "${install_root}"
  mv "${tmp_dir}/${zig_root_dir}" "${install_root}"
  rm -rf "${tmp_dir}"
  trap - EXIT
fi

echo "${install_root}" >> "${GITHUB_PATH}"
"${install_root}/zig" version
