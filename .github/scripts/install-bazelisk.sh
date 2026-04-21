#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_PATH:?GITHUB_PATH environment variable is required}"

bazelisk_version="${BAZELISK_VERSION:-v1.27.0}"
runner_temp="${RUNNER_TEMP:-/tmp}"

case "$(uname -s):$(uname -m)" in
  Linux:x86_64)
    asset_name="bazelisk-linux-amd64"
    asset_sha256="e1508323f347ad1465a887bc5d2bfb91cffc232d11e8e997b623227c6b32fb76"
    ;;
  Linux:aarch64|Linux:arm64)
    asset_name="bazelisk-linux-arm64"
    asset_sha256="bb608519a440d45d10304eb684a73a2b6bb7699c5b0e5434361661b25f113a5d"
    ;;
  Darwin:x86_64)
    asset_name="bazelisk-darwin-amd64"
    asset_sha256="8fcd7ba828f673ba4b1529425e01e15ac42599ef566c17f320d8cbfe7b96a167"
    ;;
  Darwin:arm64)
    asset_name="bazelisk-darwin-arm64"
    asset_sha256="8bf08c894ccc19ef37f286e58184c3942c58cb08da955e990522703526ddb720"
    ;;
  MINGW*:x86_64|MSYS*:x86_64|CYGWIN*:x86_64)
    asset_name="bazelisk-windows-amd64.exe"
    asset_sha256="d4b5e1cea61fcdb0bed60f8868c2e37684221b65feae898d1124482cd39ec89e"
    ;;
  MINGW*:aarch64|MSYS*:aarch64|CYGWIN*:aarch64|MINGW*:arm64|MSYS*:arm64|CYGWIN*:arm64)
    asset_name="bazelisk-windows-arm64.exe"
    asset_sha256="46d97f32458cd88dd4c2c6ad1c597e02d38ee3a1d07b07715c5a9e1b0c09a6dc"
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
