#!/usr/bin/env bash
set -euo pipefail

: "${SOURCE_SHA:?SOURCE_SHA is required}"
: "${CONTROL_SHA:?CONTROL_SHA is required}"
: "${EXPECTED_PACKAGE_VERSION:?EXPECTED_PACKAGE_VERSION is required}"
: "${TERMUX_APK:?TERMUX_APK is required}"
: "${EMULATOR_DIST:?EMULATOR_DIST is required}"

PREFIX_DIR="/data/data/com.termux/files/usr"
HOME_DIR="/data/data/com.termux/files/home"
PORT="${TERMUX_FIXTURE_PORT:-8765}"
LOG_DIR="${GITHUB_WORKSPACE}/android-termux-logs"
mkdir -p "$LOG_DIR"

python3 -m http.server "$PORT" \
  --bind 0.0.0.0 \
  --directory "$EMULATOR_DIST" \
  >"$LOG_DIR/http-server.log" 2>&1 &
server_pid=$!

cleanup() {
  kill "$server_pid" 2>/dev/null || true
  adb logcat -d >"$LOG_DIR/logcat.txt" 2>&1 || true
  adb shell dumpsys package com.termux >"$LOG_DIR/termux-package.txt" 2>&1 || true
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 30); do
  curl -fsS "http://127.0.0.1:${PORT}/current/metadata.env" >/dev/null && break
  sleep 1
done
curl -fsS "http://127.0.0.1:${PORT}/current/metadata.env" >/dev/null

wait_for_android_settle() {
  adb wait-for-device
  local boot_completed="" boot_animation=""
  for _ in $(seq 1 180); do
    boot_completed="$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
    boot_animation="$(adb shell getprop init.svc.bootanim 2>/dev/null | tr -d '\r')"
    if [[ "$boot_completed" == "1" && "$boot_animation" == "stopped" ]]; then
      break
    fi
    sleep 2
  done
  [[ "$boot_completed" == "1" && "$boot_animation" == "stopped" ]] || {
    echo "Android did not reach a stable completed boot state" >&2
    return 1
  }

  # Termux starts its bootstrap from Activity.onCreate(). A late Android theme,
  # density or rotation relaunch can invoke onCreate() again while extraction is
  # still active, causing two installer threads to race over usr-staging.
  adb shell settings put system accelerometer_rotation 0 >/dev/null 2>&1 || true
  adb shell settings put system user_rotation 0 >/dev/null 2>&1 || true
  adb shell cmd activity wait-for-broadcast-idle >/dev/null 2>&1 || true
  adb shell am wait-for-broadcast-idle >/dev/null 2>&1 || true
  sleep 45
}

bootstrap_termux() {
  local attempt="$1"
  adb shell am force-stop com.termux >/dev/null 2>&1 || true
  adb shell run-as com.termux sh -c \
    'rm -rf files/usr files/usr-staging' >/dev/null 2>&1 || true
  sleep 3
  adb logcat -c >/dev/null 2>&1 || true
  adb shell am start -W -n com.termux/.app.TermuxActivity \
    >"$LOG_DIR/activity-start-${attempt}.txt"

  for _ in $(seq 1 180); do
    if adb shell run-as com.termux ls files/usr/bin/bash >/dev/null 2>&1; then
      adb shell run-as com.termux files/usr/bin/bash --version >/dev/null 2>&1
      return 0
    fi
    sleep 2
  done
  adb logcat -d >"$LOG_DIR/bootstrap-attempt-${attempt}.log" 2>&1 || true
  return 1
}

wait_for_android_settle
adb install -r "$TERMUX_APK"

ready=no
for attempt in 1 2; do
  if bootstrap_termux "$attempt"; then
    ready=yes
    break
  fi
  echo "Termux bootstrap attempt ${attempt} did not complete; resetting the app prefix before retry." >&2
  sleep 10
done
[[ "$ready" == yes ]] || {
  echo "Termux bootstrap did not create ${PREFIX_DIR}/bin/bash after two clean attempts" >&2
  exit 1
}

fixture_archive="${RUNNER_TEMP}/termux-emulator-fixtures.tar.gz"
tar -C "$EMULATOR_DIST" -czf "$fixture_archive" .
adb push "$fixture_archive" /data/local/tmp/termux-emulator-fixtures.tar.gz >/dev/null
adb shell chmod 0644 /data/local/tmp/termux-emulator-fixtures.tar.gz
adb shell run-as com.termux cp \
  /data/local/tmp/termux-emulator-fixtures.tar.gz \
  files/home/termux-emulator-fixtures.tar.gz

termux_script="${RUNNER_TEMP}/termux-native-validation.sh"
cat >"$termux_script" <<EOF_TERMUX
#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

report_error() {
  local status=\$?
  printf 'termux-native-validation: line %s: command failed (exit %s): %s\n' \
    "\${BASH_LINENO[0]:-unknown}" "\${status}" "\${BASH_COMMAND:-unknown}" >&2
  exit "\${status}"
}
trap report_error ERR

export PREFIX="${PREFIX_DIR}"
export HOME="${HOME_DIR}"
export PATH="\${PREFIX}/bin:/system/bin"
export TMPDIR="\${PREFIX}/tmp"
export TERMUX_APK_RELEASE=GITHUB
export CI=true

SOURCE_SHA="${SOURCE_SHA}"
CONTROL_SHA="${CONTROL_SHA}"
EXPECTED_PACKAGE_VERSION="${EXPECTED_PACKAGE_VERSION}"

mkdir -p "\${HOME}/emulator-dist"
tar -xzf "\${HOME}/termux-emulator-fixtures.tar.gz" -C "\${HOME}/emulator-dist"
PREVIOUS_SHA="\$(sed -n 's/^head_sha=//p' "\${HOME}/emulator-dist/previous/release-manifest.env")"

pkg update -y
pkg install -y bash git curl ca-certificates coreutils findutils tar gzip nodejs proot termux-tools ripgrep

mkdir -p "\${HOME}/ci-uname-shim"
cat >"\${HOME}/ci-uname-shim/uname" <<'EOF_UNAME'
#!/data/data/com.termux/files/usr/bin/bash
if [[ "\${1:-}" == "-m" ]]; then
  printf '%s\n' aarch64
  exit 0
fi
exec /system/bin/uname "\$@"
EOF_UNAME
chmod 0755 "\${HOME}/ci-uname-shim/uname"
export PATH="\${HOME}/ci-uname-shim:\${PREFIX}/bin:/system/bin"

rm -rf "\${HOME}/codex-ci" "\${HOME}/codex-control-origin.git"
mkdir -p "\${HOME}/codex-ci"
git -C "\${HOME}/codex-ci" init
git -C "\${HOME}/codex-ci" remote add seed \
  "https://github.com/${GITHUB_REPOSITORY}.git"
git -C "\${HOME}/codex-ci" fetch --depth=1 seed "\${CONTROL_SHA}"
git -C "\${HOME}/codex-ci" checkout -B main FETCH_HEAD
test "\$(git -C "\${HOME}/codex-ci" rev-parse HEAD)" = "\${CONTROL_SHA}"
git -C "\${HOME}/codex-ci" remote remove seed
git clone --bare "\${HOME}/codex-ci" "\${HOME}/codex-control-origin.git"
git --git-dir="\${HOME}/codex-control-origin.git" update-ref refs/heads/main "\${CONTROL_SHA}"

# Keep the repository identity GitHub-shaped so the production remote guards are
# exercised. Route the SSH transport to the exact local mirror instead of
# weakening those guards for a file://-only CI checkout.
ci_git_mirror="\${HOME}/codex-control-origin.git"
ci_git_ssh="\${HOME}/ci-git-ssh"
cat >"\${ci_git_ssh}" <<'EOF_GIT_SSH'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
: "\${CODEX_TERMUX_CI_GIT_MIRROR:?CODEX_TERMUX_CI_GIT_MIRROR is required}"
exec git-upload-pack "\${CODEX_TERMUX_CI_GIT_MIRROR}"
EOF_GIT_SSH
chmod 0755 "\${ci_git_ssh}"
export CODEX_TERMUX_CI_GIT_MIRROR="\${ci_git_mirror}"
export GIT_SSH_COMMAND="\${ci_git_ssh}"
export GIT_SSH_VARIANT=ssh
ci_fork_url="git@github.com:${GITHUB_REPOSITORY}.git"
git -C "\${HOME}/codex-ci" remote add origin "\${ci_fork_url}"
export CODEX_TERMUX_FORK_URL="\${ci_fork_url}"
test "\$(git -C "\${HOME}/codex-ci" remote get-url origin)" = "\${ci_fork_url}"
test "\$(git -C "\${HOME}/codex-ci" ls-remote origin refs/heads/main | awk '{print \$1}')" = "\${CONTROL_SHA}"

updater="\${HOME}/codex-ci/scripts/termux/codex-update-alpha"
sed -i \
  's#local base="https://github.com/\${CODEX_TERMUX_REPO}/releases/download/\${release_tag}"#local base="\${CODEX_TERMUX_CI_RELEASE_BASE_URL:-https://github.com/\${CODEX_TERMUX_REPO}/releases/download/\${release_tag}}"#' \
  "\${updater}"
grep -F 'CODEX_TERMUX_CI_RELEASE_BASE_URL' "\${updater}" >/dev/null
git -C "\${HOME}/codex-ci" update-index --assume-unchanged scripts/termux/codex-update-alpha
test -z "\$(git -C "\${HOME}/codex-ci" status --porcelain)"

export CODEX_SRC_DIR="\${HOME}/codex-ci"
export CODEX_TERMUX_RELEASE_MANIFEST="\${HOME}/emulator-dist/previous/release-manifest.env"
export CODEX_TERMUX_CI_RELEASE_BASE_URL="http://10.0.2.2:${PORT}/previous"

bash "\${CODEX_SRC_DIR}/scripts/termux/install-codex-termux"

expected_binary_version="codex-cli \${SOURCE_SHA:0:7}"
test "\$(codex --version)" = "\${expected_binary_version}"
CODEX_TERMUX_DISABLE_PROOT=1 smoke-test-artifact --installed
codex --termux-launcher-check
codex --help >/dev/null
codex login --help >/dev/null
codex mcp --help >/dev/null
codex mcp-server --help >/dev/null
codex plugin --help >/dev/null
codex sandbox --help >/dev/null

if codex login status >"\${HOME}/login-status.log" 2>&1; then
  echo "A pre-existing login was unexpectedly present in the clean emulator" >&2
  exit 1
fi
grep -Eiq 'not logged|login|authentication|credentials' "\${HOME}/login-status.log"

set +e
timeout 20 codex login --device-auth >"\${HOME}/device-auth.log" 2>&1
device_auth_status=\$?
set -e
if [[ "\${device_auth_status}" -ne 0 && "\${device_auth_status}" -ne 124 ]]; then
  grep -Eiq 'device|browser|login|auth|network|request' "\${HOME}/device-auth.log" || {
    cat "\${HOME}/device-auth.log" >&2
    exit 1
  }
fi

curl -fsS https://api.github.com/zen >"\${HOME}/github-network.txt"
openai_status="\$(curl -sS -o /dev/null -w '%{http_code}' https://api.openai.com/v1/models)"
case "\${openai_status}" in
  401|403) ;;
  *)
    echo "Unexpected unauthenticated OpenAI API status: \${openai_status}" >&2
    exit 1
    ;;
esac

cat >"\${HOME}/mcp-stdio-smoke.js" <<'EOF_NODE'
let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => {
  buffer += chunk;
  let newline;
  while ((newline = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, newline);
    buffer = buffer.slice(newline + 1);
    if (!line.trim()) continue;
    const message = JSON.parse(line);
    process.stdout.write(JSON.stringify({
      jsonrpc: "2.0",
      id: message.id,
      result: {
        protocolVersion: "2025-03-26",
        capabilities: {},
        serverInfo: { name: "termux-ci", version: "1.0.0" }
      }
    }) + "\n");
  }
});
EOF_NODE
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' |
  node "\${HOME}/mcp-stdio-smoke.js" |
  grep -F '"id":1' >/dev/null

set +e
timeout 5 codex mcp-server </dev/null >"\${HOME}/codex-mcp-server.log" 2>&1
mcp_server_status=\$?
set -e
case "\${mcp_server_status}" in
  0|124) ;;
  *)
    cat "\${HOME}/codex-mcp-server.log" >&2
    exit 1
    ;;
esac

mkdir -p "\${HOME}/sandbox-workspace"
rm -f \
  "\${HOME}/sandbox-workspace/read-only-denied" \
  "\${HOME}/sandbox-workspace/workspace-write-ok" \
  "\${HOME}/sandbox-outside-denied"

set +e
(
  cd "\${HOME}/sandbox-workspace"
  CODEX_TERMUX_DISABLE_PROOT=1 codex \
    -c 'sandbox_mode="read-only"' \
    sandbox -- sh -c 'touch read-only-denied'
) >"\${HOME}/sandbox-read-only.log" 2>&1
read_only_status=\$?
set -e
test ! -e "\${HOME}/sandbox-workspace/read-only-denied"
if grep -Eiq 'unknown (configuration|config)|invalid configuration' "\${HOME}/sandbox-read-only.log"; then
  cat "\${HOME}/sandbox-read-only.log" >&2
  exit 1
fi
printf 'read-only sandbox exit=%s\n' "\${read_only_status}"

set +e
(
  cd "\${HOME}/sandbox-workspace"
  CODEX_TERMUX_DISABLE_PROOT=1 codex \
    -c 'sandbox_mode="workspace-write"' \
    sandbox -- sh -c \
    "touch workspace-write-ok; touch '\${HOME}/sandbox-outside-denied'"
) >"\${HOME}/sandbox-workspace-write.log" 2>&1
workspace_status=\$?
set -e
test ! -e "\${HOME}/sandbox-outside-denied"
if [[ ! -e "\${HOME}/sandbox-workspace/workspace-write-ok" ]]; then
  grep -Eiq 'sandbox|landlock|read-only|permission|not supported|downgrad' \
    "\${HOME}/sandbox-workspace-write.log" || {
      cat "\${HOME}/sandbox-workspace-write.log" >&2
      exit 1
    }
fi
printf 'workspace-write sandbox exit=%s\n' "\${workspace_status}"

export CODEX_TERMUX_RELEASE_MANIFEST="\${HOME}/emulator-dist/current/release-manifest.env"
export CODEX_TERMUX_CI_RELEASE_BASE_URL="http://10.0.2.2:${PORT}/current"
codex-update-alpha update

source "\${PREFIX}/bin/termux-mobile-lib.sh"
test "\$(termux_current_release_sha "\${PREFIX}")" = "\${SOURCE_SHA}"
codex-update-alpha list-installed | tee "\${HOME}/installed-releases.log"
grep -F "\${SOURCE_SHA}" "\${HOME}/installed-releases.log"
grep -F "\${PREVIOUS_SHA}" "\${HOME}/installed-releases.log"

codex-update-alpha rollback
test "\$(termux_current_release_sha "\${PREFIX}")" = "\${PREVIOUS_SHA}"
codex-update-alpha activate --expected-sha "\${SOURCE_SHA}"
test "\$(termux_current_release_sha "\${PREFIX}")" = "\${SOURCE_SHA}"

before_sha="\$(termux_current_release_sha "\${PREFIX}")"
export CODEX_TERMUX_RELEASE_MANIFEST="\${HOME}/emulator-dist/broken/release-manifest.env"
export CODEX_TERMUX_CI_RELEASE_BASE_URL="http://10.0.2.2:${PORT}/broken"
set +e
codex-update-alpha update >"\${HOME}/broken-update.log" 2>&1
broken_status=\$?
set -e
test "\${broken_status}" -ne 0
test "\$(termux_current_release_sha "\${PREFIX}")" = "\${before_sha}"
grep -Eiq 'sha|checksum|integrity|incomplete|failed' "\${HOME}/broken-update.log"

export CODEX_TERMUX_RELEASE_MANIFEST="\${HOME}/emulator-dist/lowspace/release-manifest.env"
export CODEX_TERMUX_CI_RELEASE_BASE_URL="http://10.0.2.2:${PORT}/lowspace"
export CODEX_TERMUX_AVAILABLE_BYTES=1
set +e
codex-update-alpha update >"\${HOME}/lowspace-update.log" 2>&1
lowspace_status=\$?
set -e
unset CODEX_TERMUX_AVAILABLE_BYTES
test "\${lowspace_status}" -ne 0
test "\$(termux_current_release_sha "\${PREFIX}")" = "\${before_sha}"
grep -F 'insufficient storage' "\${HOME}/lowspace-update.log"

printf '%s\n' \
  "android_release=\$(getprop ro.build.version.release)" \
  "android_sdk=\$(getprop ro.build.version.sdk)" \
  "termux_package=\${TERMUX_APK_RELEASE}" \
  "machine_real=\$(/system/bin/uname -m)" \
  "runtime_source=\${SOURCE_SHA}" \
  "package_version=\${EXPECTED_PACKAGE_VERSION}" \
  "binary_version=\$(codex --version)" \
  >"\${HOME}/validation-summary.env"
cat "\${HOME}/validation-summary.env"
EOF_TERMUX

chmod 0755 "$termux_script"
adb push "$termux_script" /data/local/tmp/termux-native-validation.sh >/dev/null
adb shell chmod 0644 /data/local/tmp/termux-native-validation.sh
adb shell run-as com.termux cp \
  /data/local/tmp/termux-native-validation.sh \
  files/home/termux-native-validation.sh
adb shell run-as com.termux chmod 0755 files/home/termux-native-validation.sh

set +e
adb shell run-as com.termux "$PREFIX_DIR/bin/bash" \
  "$HOME_DIR/termux-native-validation.sh" \
  2>&1 | tee "$LOG_DIR/native-validation.log"
validation_status=${PIPESTATUS[0]}
set -e

for file in \
  validation-summary.env \
  login-status.log \
  device-auth.log \
  github-network.txt \
  codex-mcp-server.log \
  sandbox-read-only.log \
  sandbox-workspace-write.log \
  installed-releases.log \
  broken-update.log \
  lowspace-update.log; do
  adb exec-out run-as com.termux cat "files/home/${file}" \
    >"$LOG_DIR/${file}" 2>/dev/null || true
done

exit "$validation_status"
