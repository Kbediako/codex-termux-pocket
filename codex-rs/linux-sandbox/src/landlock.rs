//! In-process Linux sandbox primitives: `no_new_privs` and seccomp.
//!
//! Filesystem restrictions are enforced by bubblewrap in `linux_run_main`.
//! Landlock remains the legacy filesystem backend, with a fail-closed
//! read-only seccomp fallback for Android/Termux app processes that cannot
//! access the Landlock syscalls.
mod termux_read_only_seccomp;

use std::collections::BTreeMap;
use std::collections::BTreeSet;
use std::ffi::CString;
use std::os::fd::AsRawFd;
use std::os::fd::FromRawFd;
use std::os::fd::OwnedFd;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::path::PathBuf;

use codex_protocol::error::CodexErr;
use codex_protocol::error::Result;
use codex_protocol::error::SandboxErr;
use codex_protocol::models::PermissionProfile;
use codex_protocol::protocol::NetworkSandboxPolicy;
use codex_utils_absolute_path::AbsolutePathBuf;

use landlock::ABI;
#[allow(unused_imports)]
use landlock::Access;
use landlock::AccessFs;
use landlock::CompatLevel;
use landlock::Compatible;
use landlock::Ruleset;
use landlock::RulesetAttr;
use landlock::RulesetCreated;
use landlock::RulesetCreatedAttr;
use seccompiler::BpfProgram;
use seccompiler::SeccompAction;
use seccompiler::SeccompCmpArgLen;
use seccompiler::SeccompCmpOp;
use seccompiler::SeccompCondition;
use seccompiler::SeccompFilter;
use seccompiler::SeccompRule;
use seccompiler::TargetArch;
use seccompiler::apply_filter;

/// Apply sandbox policies inside this thread so only the child inherits
/// them, not the entire CLI process.
///
/// This function is responsible for:
/// - enabling `PR_SET_NO_NEW_PRIVS` when restrictions apply, and
/// - installing the network seccomp filter when network access is disabled.
///
/// Filesystem restrictions are intentionally handled by bubblewrap.
pub(crate) fn apply_permission_profile_to_current_thread(
    permission_profile: &PermissionProfile,
    cwd: &Path,
    apply_landlock_fs: bool,
    allow_network_for_proxy: bool,
    proxy_routed_network: bool,
) -> Result<()> {
    let (file_system_sandbox_policy, network_sandbox_policy) =
        permission_profile.to_runtime_permissions();
    let network_seccomp_mode = network_seccomp_mode(
        network_sandbox_policy,
        allow_network_for_proxy,
        proxy_routed_network,
    );

    // `PR_SET_NO_NEW_PRIVS` is required for seccomp, but it also prevents
    // setuid privilege elevation. Many `bwrap` deployments rely on setuid, so
    // we avoid this unless we need seccomp or we are explicitly using the
    // legacy Landlock filesystem pipeline.
    if network_seccomp_mode.is_some()
        || (apply_landlock_fs && !file_system_sandbox_policy.has_full_disk_write_access())
    {
        set_no_new_privs()?;
    }

    if let Some(mode) = network_seccomp_mode {
        install_network_seccomp_filter_on_current_thread(mode)?;
    }

    if apply_landlock_fs && !file_system_sandbox_policy.has_full_disk_write_access() {
        if !file_system_sandbox_policy.has_full_disk_read_access() {
            return Err(CodexErr::UnsupportedOperation(
                "Restricted read-only access is not supported by the legacy Linux filesystem backend."
                    .to_string(),
            ));
        }

        let writable_roots = file_system_sandbox_policy
            .get_writable_roots_with_cwd(cwd)
            .into_iter()
            .map(|writable_root| writable_root.root)
            .collect();

        if is_termux_environment() {
            match current_landlock_abi(ABI::V5) {
                Ok(effective_abi) if effective_abi != ABI::Unsupported => {
                    if let Err(error) = install_filesystem_landlock_rules_on_current_thread(
                        writable_roots,
                        Some(effective_abi),
                    ) {
                        eprintln!(
                            "codex-linux-sandbox: Termux Landlock setup failed ({error:?}); enforcing a global read-only filesystem policy with seccomp"
                        );
                        termux_read_only_seccomp::install_on_current_thread()?;
                    }
                }
                Ok(_) => {
                    eprintln!(
                        "codex-linux-sandbox: Termux Landlock reports no supported ABI; enforcing a global read-only filesystem policy with seccomp"
                    );
                    termux_read_only_seccomp::install_on_current_thread()?;
                }
                Err(error) => {
                    eprintln!(
                        "codex-linux-sandbox: Termux Landlock is unavailable ({error}); enforcing a global read-only filesystem policy with seccomp"
                    );
                    termux_read_only_seccomp::install_on_current_thread()?;
                }
            }
        } else {
            install_filesystem_landlock_rules_on_current_thread(writable_roots, None)?;
        }
    }

    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum NetworkSeccompMode {
    Restricted,
    ProxyRouted,
}

fn should_install_network_seccomp(
    network_sandbox_policy: NetworkSandboxPolicy,
    allow_network_for_proxy: bool,
) -> bool {
    // Managed-network sessions should remain fail-closed even for policies that
    // would normally grant full network access (for example, DangerFullAccess).
    !network_sandbox_policy.is_enabled() || allow_network_for_proxy
}

fn network_seccomp_mode(
    network_sandbox_policy: NetworkSandboxPolicy,
    allow_network_for_proxy: bool,
    proxy_routed_network: bool,
) -> Option<NetworkSeccompMode> {
    if !should_install_network_seccomp(network_sandbox_policy, allow_network_for_proxy) {
        None
    } else if proxy_routed_network {
        Some(NetworkSeccompMode::ProxyRouted)
    } else {
        Some(NetworkSeccompMode::Restricted)
    }
}

/// Enable `PR_SET_NO_NEW_PRIVS` so seccomp can be applied safely.
fn set_no_new_privs() -> Result<()> {
    let result = unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) };
    if result != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(())
}

/// Installs Landlock file-system rules on the current thread allowing read
/// access to the entire file-system while restricting write access to
/// `/dev/null` and the provided list of `writable_roots`.
///
/// # Errors
/// Returns [`CodexErr::Sandbox`] variants when the ruleset fails to apply.
///
/// Note: this is currently unused because filesystem sandboxing is performed
/// via bubblewrap. It is kept for reference and potential fallback use.
fn install_filesystem_landlock_rules_on_current_thread(
    writable_roots: Vec<AbsolutePathBuf>,
    termux_effective_abi: Option<ABI>,
) -> Result<()> {
    let abi = ABI::V5;
    let access_rw = AccessFs::from_all(abi);
    let access_ro = AccessFs::from_read(abi);

    let readable_roots = legacy_readable_roots();
    let mut ruleset = Ruleset::default()
        .set_compatibility(CompatLevel::BestEffort)
        .handle_access(access_rw)?
        .create()?
        .add_rules(landlock::path_beneath_rules(&["/dev/null"], access_rw))?;

    if !writable_roots.is_empty() {
        ruleset = ruleset.add_rules(landlock::path_beneath_rules(&writable_roots, access_rw))?;
    }

    if let Some(effective_abi) = termux_effective_abi {
        return install_termux_read_rules_and_restrict(
            ruleset,
            &readable_roots,
            abi,
            effective_abi,
        );
    }

    let status = ruleset.add_rules(landlock::path_beneath_rules(
        