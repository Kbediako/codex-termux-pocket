#!/usr/bin/env bash
set -euo pipefail

: "${SOURCE_DIR:?SOURCE_DIR is required}"
: "${SOURCE_SHA:?SOURCE_SHA is required}"
: "${EXPECTED_PACKAGE_VERSION:?EXPECTED_PACKAGE_VERSION is required}"
: "${TARGET:=x86_64-unknown-linux-musl}"

CODEX_DIR="${SOURCE_DIR}/codex-rs"
FIXTURE_ROOT="${GITHUB_WORKSPACE}/dist/android-emulator"
RUNTIME_PARENT="${FIXTURE_ROOT}/runtime"
RUNTIME_ROOT="${RUNTIME_PARENT}/codex-termux-runtime"
ARCHIVE_NAME="codex-termux-aarch64-unknown-linux-musl.tar.gz"

[[ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" == "$SOURCE_SHA" ]]
actual_version="$(
  awk '
    /^\[workspace\.package\]$/ { in_package=1; next }
    /^\[/ && in_package { exit }
    in_package && /^version[[:space:]]*=/ {
      value=$0
      sub(/^[^=]*=[[:space:]]*"/, "", value)
      sub(/".*$/, "", value)
      print value
      exit
    }
  ' "${CODEX_DIR}/Cargo.toml"
)"
[[ "$actual_version" == "$EXPECTED_PACKAGE_VERSION" ]]

if [[ "$TARGET" == "x86_64-unknown-linux-musl" ]]; then
  cargo_linker_var="CARGO_TARGET_${TARGET^^}_LINKER"
  cargo_linker_var="${cargo_linker_var//-/_}"
  final_linker="${!cargo_linker_var:-}"
  : "${final_linker:?x86_64 musl Rust final linker is not configured}"
  : "${MUSL_GCC_LINKER:?MUSL_GCC_LINKER is not configured}"
  : "${MUSL_LLD_LINKER:?MUSL_LLD_LINKER is not configured}"

  link_stack_inputs=(
    .github/scripts/build-termux-android-emulator-fixture.sh
    .github/scripts/check-x86_64-musl-linker-interop.sh
    .github/scripts/install-musl-build-tools.sh
    .github/scripts/install-musl-build-tools-core-49035f.sh
    .github/scripts/install-zig.sh
    .github/scripts/rusty_v8_bazel.py
    .github/scripts/x86_64-linux-musl-rust-linker.sh
    codex-rs/Cargo.lock
    codex-rs/rust-toolchain.toml
  )
  link_stack_fingerprint="$(
    {
      printf 'target=%s\n' "$TARGET"
      printf 'zig_version=%s\n' "${ZIG_VERSION:-unset}"
      printf 'rusty_v8_version=%s\n' "${RUSTY_V8_VERSION:-unset}"
      printf 'rusty_v8_archive_sha256=%s\n' "${RUSTY_V8_ARCHIVE_SHA256:-unset}"
      printf 'rusty_v8_binding_sha256=%s\n' "${RUSTY_V8_BINDING_SHA256:-unset}"
      printf 'final_linker=%s\n' "$final_linker"
      printf 'musl_gcc=%s\n' "$MUSL_GCC_LINKER"
      printf 'lld=%s\n' "$MUSL_LLD_LINKER"
      for input in "${link_stack_inputs[@]}"; do
        input_path="${SOURCE_DIR}/${input}"
        test -f "$input_path"
        printf '%s  %s\n' "$(sha256sum "$input_path" | awk '{print $1}')" "$input"
      done
      rustc --version --verbose
      cargo --version
      zig version
      "$MUSL_GCC_LINKER" --version
      "$MUSL_LLD_LINKER" --version
    } | sha256sum | awk '{print $1}'
  )"
  test -n "$link_stack_fingerprint"

  target_root="${CODEX_DIR}/target"
  target_release="${target_root}/${TARGET}/release"
  marker_dir="${target_release}/.fingerprint"
  marker="${marker_dir}/termux-link-stack-${link_stack_fingerprint}.ok"
  if [[ -d "$target_root" && ! -f "$marker" ]]; then
    echo "Discarding compiled target cache from a different native link stack"
    rm -rf \
      "${target_root}/release/.fingerprint" \
      "${target_root}/release/build" \
      "${target_root}/release/deps" \
      "${target_release}/.fingerprint" \
      "${target_release}/build" \
      "${target_release}/deps" \
      "${target_release}/gn_out/obj"
  fi
  mkdir -p "$marker_dir"
  printf '%s\n' "$link_stack_fingerprint" >"$marker"
  echo "native_link_stack_fingerprint=${link_stack_fingerprint}"
fi

cd "$CODEX_DIR"
cargo metadata --locked --format-version=1 >/dev/null
cargo build --locked --target "$TARGET" --release \
  --bin codex \
  --bin codex-code-mode-host \
  --bin codex-responses-api-proxy

rm -rf "$FIXTURE_ROOT"
mkdir -p "${RUNTIME_ROOT}/bin" "${RUNTIME_ROOT}/codex-resources"

for binary in codex codex-code-mode-host codex-responses-api-proxy; do
  cp "target/${TARGET}/release/${binary}" "${RUNTIME_ROOT}/bin/${binary}"
  strip --strip-debug --strip-unneeded "${RUNTIME_ROOT}/bin/${binary}"
  chmod 0755 "${RUNTIME_ROOT}/bin/${binary}"
done

cat >"${RUNNER_TEMP}/bwrap-termux-ci.c" <<'EOF_BWRAP'
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "--version") == 0) {
    puts("bubblewrap 0.0.0-termux-android-ci");
    return 0;
  }
  fputs(
    "The Android emulator surrogate intentionally disables bubblewrap; use the Landlock fallback.\n",
    stderr
  );
  return 125;
}
EOF_BWRAP
"${CC:-cc}" -static -Os \
  "${RUNNER_TEMP}/bwrap-termux-ci.c" \
  -o "${RUNTIME_ROOT}/codex-resources/bwrap"
strip --strip-debug --strip-unneeded "${RUNTIME_ROOT}/codex-resources/bwrap"
chmod 0755 "${RUNTIME_ROOT}/codex-resources/bwrap"

python3 - <<'PY'
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

root = Path(os.environ["GITHUB_WORKSPACE"]) / "dist/android-emulator/runtime/codex-termux-runtime"
version = os.popen(f"{root / 'bin/codex'} --version").read().strip()
package = {
    "layoutVersion": 1,
    "version": version,
    "target": "aarch64-unknown-linux-musl",
    "variant": "android-emulator-surrogate",
    "entrypoint": "bin/codex",
    "resourcesDir": "codex-resources",
}
(root / "codex-package.json").write_text(
    json.dumps(package, indent=2) + "\n",
    encoding="utf-8",
)
lines: list[str] = []
for path in sorted(item for item in root.rglob("*") if item.is_file()):
    relative = path.relative_to(root).as_posix()
    lines.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {relative}")
(root / "runtime-files.sha256").write_text(
    "\n".join(lines) + "\n",
    encoding="utf-8",
)
PY

version="$("${RUNTIME_ROOT}/bin/codex" --version)"
expected_version="codex-cli ${SOURCE_SHA:0:7}"
[[ "$version" == "$expected_version" ]]
(
  cd "$RUNTIME_ROOT"
  sha256sum --check --strict runtime-files.sha256
)
"${RUNTIME_ROOT}/bin/codex-code-mode-host" --help >/dev/null
"${RUNTIME_ROOT}/bin/codex-responses-api-proxy" --help >/dev/null
"${RUNTIME_ROOT}/codex-resources/bwrap" --version >/dev/null

source_date_epoch="$(git -C "$SOURCE_DIR" show -s --format=%ct HEAD)"
archive="${RUNTIME_PARENT}/${ARCHIVE_NAME}"
tar --sort=name \
  --mtime="@${source_date_epoch}" \
  --owner=0 --group=0 --numeric-owner \
  -C "$RUNTIME_PARENT" -cf - codex-termux-runtime |
  gzip -n -9 >"$archive"

archive_size="$(stat -c '%s' "$archive")"
runtime_size="$(
  find "$RUNTIME_ROOT" -type f -printf '%s\n' |
    awk '{ total += $1 } END { printf "%.0f\n", total }'
)"
archive_sha="$(sha256sum "$archive" | awk '{print $1}')"
previous_sha="$(git -C "$SOURCE_DIR" rev-parse HEAD^)"
broken_sha="dddddddddddddddddddddddddddddddddddddddd"
lowspace_sha="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

create_fixture() {
  local name="$1"
  local head_sha="$2"
  local tag="$3"
  local dir="${FIXTURE_ROOT}/${name}"
  mkdir -p "$dir"
  cp "$archive" "${dir}/${ARCHIVE_NAME}"
  cat >"${dir}/metadata.env" <<EOF_METADATA
format_version=2
source_repository=${GITHUB_REPOSITORY}
head_sha=${head_sha}
git_describe=android-emulator-surrogate
codex_version=${version}
target=aarch64-unknown-linux-musl
source_ref=android-emulator-surrogate
archive_size_bytes=${archive_size}
runtime_size_bytes=${runtime_size}
EOF_METADATA
  (
    cd "$dir"
    sha256sum "$ARCHIVE_NAME" metadata.env >SHA256SUMS
  )
  cat >"${dir}/release-manifest.env" <<EOF_MANIFEST
format_version=2
repository=${GITHUB_REPOSITORY}
release_tag=${tag}
head_sha=${head_sha}
codex_version=${version}
archive_sha256=${archive_sha}
archive_size_bytes=${archive_size}
runtime_size_bytes=${runtime_size}
EOF_MANIFEST
}

create_fixture previous "$previous_sha" termux-vci-previous
create_fixture current "$SOURCE_SHA" termux-vci-current
create_fixture broken "$broken_sha" termux-vci-broken
create_fixture lowspace "$lowspace_sha" termux-vci-lowspace
truncate -s $(( archive_size / 2 )) "${FIXTURE_ROOT}/broken/${ARCHIVE_NAME}"
rm -rf "$RUNTIME_PARENT"

cat >"${FIXTURE_ROOT}/fixture.env" <<EOF_FIXTURE
source_sha=${SOURCE_SHA}
previous_sha=${previous_sha}
package_version=${EXPECTED_PACKAGE_VERSION}
binary_version=${version}
build_machine=$(uname -m)
runtime_machine=x86_64
production_identity=aarch64-unknown-linux-musl
EOF_FIXTURE

for name in previous current broken lowspace; do
  test -f "${FIXTURE_ROOT}/${name}/release-manifest.env"
  test -f "${FIXTURE_ROOT}/${name}/${ARCHIVE_NAME}"
done
printf 'Built Android emulator fixture for %s (%s)\n' "$SOURCE_SHA" "$version"
