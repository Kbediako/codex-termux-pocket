#!/usr/bin/env bash
set -euo pipefail

base_script="${RUNNER_TEMP:?RUNNER_TEMP is required}/alpha1515-base.sh"
runtime_script="$RUNNER_TEMP/alpha1515-maintenance-runtime.sh"
cat .github/scripts/alpha1515-maintenance.part* | base64 --decode >"$base_script"

python3 - "$base_script" "$runtime_script" <<'PY'
from pathlib import Path
import re
import sys

source_path = Path(sys.argv[1])
runtime_path = Path(sys.argv[2])
source = source_path.read_text(encoding="utf-8")

replacements = (
    ("rust-v0.150.0-alpha.13", "rust-v0.151.0-alpha.5"),
    ("c080ad22b3744f3cefcdeeb134ee17c0093d16a1", "e6e0c4fb8c0340800f4066c50e849149e4ecd912"),
    ("0.150.0-alpha.13", "0.151.0-alpha.5"),
    ("alpha13", "alpha1515"),
    ("alpha.13", "0.151.0-alpha.5"),
)
for old, new in replacements:
    source = source.replace(old, new)

old_check = r'''[[ "$(git ls-remote upstream refs/heads/latest-alpha-cli | awk '{print $1}')" == "$UPSTREAM_COMMIT" ]]'''
new_check = r'''[[ "$(git ls-remote upstream "refs/tags/${UPSTREAM_TAG}^{}" | awk '{print $1}')" == "$UPSTREAM_COMMIT" ]]'''
if source.count(old_check) != 2:
    raise SystemExit("unexpected moving-branch check count")
source = source.replace(old_check, new_check)

source = re.sub(
    r'\nif gh issue view 85 --repo "\$GITHUB_REPOSITORY" >/dev/null 2>&1; then\n'
    r'  gh issue close 85 --repo "\$GITHUB_REPOSITORY" \\\n'
    r'    --comment "Superseded by the completed 0\.151\.0-alpha\.5 publication\." >/dev/null \|\| true\n'
    r'fi\n?',
    '\n',
    source,
)

audit_needle = '''append_patch_audit() {
  local subject="$1"
  local classification="$2"
  local reason="$3"
  local line
  line=$'subject\\t'"${subject}"$'\\t'"${classification}"$'\\t'"${reason}"
  grep -Fqx "$line" scripts/termux/patch_audit.tsv \\
    || printf '%s\\n' "$line" >> scripts/termux/patch_audit.tsv
}
'''
restore_function = audit_needle + '''
restore_from_base() {
  local base_sha="$1"
  local path="$2"
  git rm -rf --ignore-unmatch -- "$path" >/dev/null 2>&1 || true
  if git cat-file -e "${base_sha}:${path}" 2>/dev/null; then
    git checkout "$base_sha" -- "$path"
  fi
}
'''
if source.count(audit_needle) != 1:
    raise SystemExit("patch-audit insertion point changed")
source = source.replace(audit_needle, restore_function)

start_needle = '''git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
BASE_SHA="$(git rev-parse HEAD)"
'''
start_replacement = '''git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
gh api --method POST \\
  "/repos/${GITHUB_REPOSITORY}/actions/runs/32212182486/cancel" \\
  >/dev/null 2>&1 || true
BASE_SHA="$(git rev-parse HEAD)"
'''
if source.count(start_needle) != 1:
    raise SystemExit("start-state insertion point changed")
source = source.replace(start_needle, start_replacement)

merge_needle = '''[[ -z "$(git diff --name-only --diff-filter=U)" ]]

CURRENT_STEP="updating-alpha-controls"
'''
restore_block = '''[[ -z "$(git diff --name-only --diff-filter=U)" ]]

CURRENT_STEP="restoring-fork-owned-surface"
for path in \\
  .github \\
  scripts/termux \\
  README.md \\
  AGENTS.md \\
  PLANS.md \\
  EXECPLAN_voice.md \\
  EXECPLAN_voice_porcu.md \\
  EXEC_PLAN.md \\
  EXEC_PLAN_TERMUX_INSTALL.md \\
  EXEC_PLAN_mobile_build_acceleration.md \\
  .prettierignore \\
  docs/contributing.md \\
  docs/termux-agent-safety.md \\
  docs/termux-alpha-log.md \\
  docs/termux-maintainer.md \\
  docs/termux-mobile-update.md; do
  restore_from_base "$BASE_SHA" "$path"
done

CURRENT_STEP="updating-alpha-controls"
'''
if source.count(merge_needle) != 1:
    raise SystemExit("fork-surface insertion point changed")
source = source.replace(merge_needle, restore_block)

controls_needle = '''cat > scripts/termux/release-request.env <<EOF
# Exact-source validation request for Codex ${PACKAGE_VERSION}.
format_version=3
source_mode=workflow-head
release_tag_prefix=termux-v${PACKAGE_VERSION}
expected_package_version=${PACKAGE_VERSION}
EOF

append_patch_audit \\
'''
controls_replacement = '''cat > scripts/termux/release-request.env <<EOF
# Exact-source validation request for Codex ${PACKAGE_VERSION}.
format_version=3
source_mode=workflow-head
release_tag_prefix=termux-v${PACKAGE_VERSION}
expected_package_version=${PACKAGE_VERSION}
EOF

workspace_version="$(
  awk '
    /^\\[workspace\\.package\\]$/ { in_package=1; next }
    /^\\[/ && in_package { exit }
    in_package && /^version[[:space:]]*=/ {
      value=$0
      sub(/^[^=]*=[[:space:]]*"/, "", value)
      sub(/".*$/, "", value)
      print value
      exit
    }
  ' codex-rs/Cargo.toml
)"
[[ "$workspace_version" == "$PACKAGE_VERSION" ]]

append_patch_audit \\
'''
if source.count(controls_needle) != 1:
    raise SystemExit("release-control insertion point changed")
source = source.replace(controls_needle, controls_replacement)

compat_needle = '''CURRENT_STEP="refreshing-and-validating-lockfile"
pushd codex-rs >/dev/null
'''
compat_block = r'''CURRENT_STEP="adapting-linux-sandbox-proxy-lifecycle"
python3 - <<'PYCODE'
from pathlib import Path

path = Path("codex-rs/linux-sandbox/src/linux_run_main.rs")
text = path.read_text(encoding="utf-8")

old_outer = r'''        let proxy_route_spec = if allow_network_for_proxy {
            let (proxy_route_spec, socket_dir) = prepare_host_proxy_route_spec()
                .unwrap_or_else(|err| panic!("failed to prepare host proxy routing bridge: {err}"));
            file_system_sandbox_policy = file_system_sandbox_policy.with_additional_readable_roots(
                &sandbox_policy_cwd,
                std::slice::from_ref(&socket_dir),
            );
            Some(proxy_route_spec)
        } else {
            None
        };'''
new_outer = r'''        let (proxy_route_spec, proxy_controls) = if allow_network_for_proxy {
            let (proxy_route_spec, controls) = prepare_host_proxy_route_spec()
                .unwrap_or_else(|err| panic!("failed to prepare host proxy routing bridge: {err}"));
            (Some(proxy_route_spec), controls)
        } else {
            (None, Vec::new())
        };'''
if text.count(old_outer) != 1:
    raise SystemExit("unexpected proxy-route outer-stage block")
text = text.replace(old_outer, new_outer)

old_call = r'''        run_bwrap_with_proc_fallback(
            &sandbox_policy_cwd,
            command_cwd.as_deref(),
            &file_system_sandbox_policy,
            network_sandbox_policy,
            inner,
            !no_proc,
            allow_network_for_proxy,
        );'''
new_call = r'''        run_bwrap_with_proc_fallback(
            &sandbox_policy_cwd,
            command_cwd.as_deref(),
            &file_system_sandbox_policy,
            bwrap_network_mode(network_sandbox_policy, allow_network_for_proxy),
            inner,
            proxy_controls,
            !no_proc,
        );'''
if text.count(old_call) != 1:
    raise SystemExit("unexpected bubblewrap call block")
text = text.replace(old_call, new_call)

old_function = r'''fn run_bwrap_with_proc_fallback(
    sandbox_policy_cwd: &Path,
    command_cwd: Option<&Path>,
    file_system_sandbox_policy: &FileSystemSandboxPolicy,
    network_sandbox_policy: NetworkSandboxPolicy,
    inner: Vec<String>,
    mount_proc: bool,
    allow_network_for_proxy: bool,
) -> ! {
    let network_mode = bwrap_network_mode(network_sandbox_policy, allow_network_for_proxy);
    let mut mount_proc = mount_proc;'''
new_function = r'''fn run_bwrap_with_proc_fallback(
    sandbox_policy_cwd: &Path,
    command_cwd: Option<&Path>,
    file_system_sandbox_policy: &FileSystemSandboxPolicy,
    network_mode: BwrapNetworkMode,
    inner: Vec<String>,
    proxy_controls: Vec<File>,
    mount_proc: bool,
) -> ! {
    let mut mount_proc = mount_proc;'''
if text.count(old_function) != 1:
    raise SystemExit("unexpected bubblewrap function signature")
text = text.replace(old_function, new_function)

old_tail = r'''    .unwrap_or_else(|err| exit_with_bwrap_build_error(err));
    apply_inner_command_argv0(&mut bwrap_args.args);
    run_or_exec_bwrap(bwrap_args);'''
new_tail = r'''    .unwrap_or_else(|err| exit_with_bwrap_build_error(err));
    bwrap_args.preserved_files.extend(proxy_controls);
    apply_inner_command_argv0(&mut bwrap_args.args);
    run_or_exec_bwrap(bwrap_args);'''
if text.count(old_tail) != 1:
    raise SystemExit("unexpected bubblewrap preserved-file tail")
text = text.replace(old_tail, new_tail)

path.write_text(text, encoding="utf-8")
PYCODE

CURRENT_STEP="refreshing-and-validating-lockfile"
pushd codex-rs >/dev/null
'''
if source.count(compat_needle) != 1:
    raise SystemExit("linux-sandbox compatibility insertion point changed")
source = source.replace(compat_needle, compat_block)

# Temporary part files are removed by the direct cleanup commit alongside the
# wrapper and workflow job. The runtime waits for the permanent topology before
# dispatching any exact-source validation.

branches_needle = '''for branch in \\
  alpha-0.150.0-alpha.8-staging \\
  alpha-0.150.0-alpha.12-staging \\
  "$STAGING_BRANCH"; do
'''
branches_replacement = '''for branch in \\
  alpha-0.150.0-alpha.8-staging \\
  alpha-0.150.0-alpha.12-staging \\
  alpha-0.150.0-alpha.13-staging \\
  "$STAGING_BRANCH"; do
'''
if source.count(branches_needle) != 1:
    raise SystemExit("branch-cleanup insertion point changed")
source = source.replace(branches_needle, branches_replacement)

if "latest-alpha-cli" in source or "alpha13" in source:
    raise SystemExit("stale alpha transaction token remains")
if "0.151.0-alpha.5" not in source or "e6e0c4fb8c0340800f4066c50e849149e4ecd912" not in source:
    raise SystemExit("exact alpha identity missing")

runtime_path.write_text(source, encoding="utf-8")
PY

bash -n "$runtime_script"
if [[ "${ALPHA1515_TRANSFORM_ONLY:-}" == "1" ]]; then
  cat "$runtime_script"
  exit 0
fi
chmod +x "$runtime_script"
exec "$runtime_script"
