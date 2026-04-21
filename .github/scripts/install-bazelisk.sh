#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_PATH:?GITHUB_PATH environment variable is required}"

bazelisk_version="${BAZELISK_VERSION:-v1.28.1}"
runner_temp="${RUNNER_TEMP:-/tmp}"

case "$(uname -s):$(uname -m)" in
  Linux:x86_64)
    asset_name="bazelisk-linux-amd64"
    asset_sha256="22e7d3a188699982f661cf4687137ee52d1f24fec1ec893d91a6c4d791a75de8"
    ;;
  Linux:aarch64|Linux:arm64)
    asset_name="bazelisk-linux-arm64"
    asset_sha256="8ded44b58a0d9425a4178af26cf17693feac3b87bdcfef0a2a0898fcd1afc9f2"
    ;;
  Darwin:x86_64)
    asset_name="bazelisk-darwin-amd64"
    asset_sha256="023225736cea5dc88f2b0807d5b1af4eb0f69a4ed45e3994b2c18c263bc80e48"
    ;;
  Darwin:arm64)
    asset_name="bazelisk-darwin-arm64"
    asset_sha256="dea3f3f5de2dbc5e269e0132cdd369d5efe738f7b973d5d4eb2b4f7055a97b39"
    ;;
  MINGW*:x86_64|MSYS*:x86_64|CYGWIN*:x86_64)
    asset_name="bazelisk-windows-amd64.exe"
    asset_sha256="b9d65a1f7c2d7af885a96a4fd5aa36b40fb41816d30944390569eef908bdc954"
    ;;
  MINGW*:aarch64|MSYS*:aarch64|CYGWIN*:aarch64|MINGW*:arm64|MSYS*:arm64|CYGWIN*:arm64)
    asset_name="bazelisk-windows-arm64.exe"
    asset_sha256="85ba3d92a8bdcbecc06657b8c0ae30f4307b552d601d9d6246f8a98aec36c346"
    ;;
  *)
    echo "Unsupported runner platform for Bazelisk install: $(uname -s):$(uname -m)" >&2
    exit 1
    ;;
esac

install_root="${runner_temp}/bazelisk-${bazelisk_version}"
install_dir="${install_root}/bin"
mkdir -p "${install_dir}"

asset_url="https://github.com/bazelbuild/bazelisk/releases/download/${bazelisk_version}/${asset_name}"

if [[ "${asset_name}" == *.exe ]]; then
  bazelisk_bin="${install_dir}/bazelisk.exe"
  bazel_bin="${install_dir}/bazel.exe"
else
  bazelisk_bin="${install_dir}/bazelisk"
  bazel_bin="${install_dir}/bazel"
fi

if [[ ! -x "${bazelisk_bin}" ]]; then
  curl -fsSL "${asset_url}" -o "${bazelisk_bin}"
  printf '%s  %s\n' "${asset_sha256}" "${bazelisk_bin}" | sha256sum -c -
  chmod +x "${bazelisk_bin}"
fi

if [[ ! -e "${bazel_bin}" ]]; then
  if [[ "${asset_name}" == *.exe ]]; then
    cp "${bazelisk_bin}" "${bazel_bin}"
  else
    ln -sf "bazelisk" "${bazel_bin}"
  fi
fi

echo "${install_dir}" >> "${GITHUB_PATH}"
printf 'Installed Bazelisk %s at %s\n' "${bazelisk_version}" "${bazelisk_bin}"
