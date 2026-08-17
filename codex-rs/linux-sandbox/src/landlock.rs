//! In-process Linux sandbox primitives: `no_new_privs` and seccomp.
//!
//! Filesystem restrictions are enforced by bubblewrap in `linux_run_main`.
//! Landlock helpers remain available here as legacy/backup utilities.
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
                "Restricted read-only access is not supported by the legacy Linux Landlock filesystem backend."
                    .to_string(),
            ));
        }

        let writable_roots = file_system_sandbox_policy
            .get_writable_roots_with_cwd(cwd)
            .into_iter()
            .map(|writable_root| writable_root.root)
            .collect();
        install_filesystem_landlock_rules_on_current_thread(writable_roots)?;
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

    if is_termux_environment() {
        return install_termux_read_rules_and_restrict(ruleset, &readable_roots, abi);
    }

    let status = ruleset
        .add_rules(landlock::path_beneath_rules(&readable_roots, access_ro))?
        .set_no_new_privs(true)
        .restrict_self()?;

    if status.ruleset == landlock::RulesetStatus::NotEnforced {
        return Err(CodexErr::Sandbox(SandboxErr::LandlockRestrict));
    }

    Ok(())
}

#[repr(C)]
struct LandlockPathBeneathAttr {
    allowed_access: u64,
    parent_fd: libc::c_int,
}

const LANDLOCK_CREATE_RULESET_VERSION: libc::c_uint = 1;
const LANDLOCK_RULE_PATH_BENEATH: libc::c_int = 1;

/// Adds read rules with the kernel UAPI on Termux, then enforces the
/// ruleset. Android SELinux permits opening some virtual roots with
/// `O_PATH` but denies the `fstat()` compatibility probe performed by
/// landlock 0.4.x. The kernel only needs the live `O_PATH` descriptor.
///
/// Writable roots and `/dev/null` still go through the crate's normal
/// compatibility checks before this function receives the ruleset.
fn install_termux_read_rules_and_restrict(
    ruleset: RulesetCreated,
    readable_roots: &[PathBuf],
    requested_abi: ABI,
) -> Result<()> {
    let effective_abi = current_landlock_abi(requested_abi)?;
    if effective_abi == ABI::Unsupported {
        return Err(CodexErr::Sandbox(SandboxErr::LandlockRestrict));
    }
    let allowed_access = termux_read_access_mask(requested_abi, effective_abi);

    let ruleset_fd: Option<OwnedFd> = ruleset.into();
    let Some(ruleset_fd) = ruleset_fd else {
        return Err(CodexErr::Sandbox(SandboxErr::LandlockRestrict));
    };

    let mut added_rules = 0usize;
    for path in readable_roots {
        // Match landlock::path_beneath_rules' best-effort behavior:
        // unavailable optional Android roots are omitted and therefore
        // remain inaccessible once this ruleset is enforced.
        let parent_fd = match open_path_for_landlock(path) {
            Ok(fd) => fd,
            Err(_) => continue,
        };
        let attr = LandlockPathBeneathAttr {
            allowed_access,
            parent_fd: parent_fd.as_raw_fd(),
        };

        // SAFETY: `ruleset_fd` and `parent_fd` are live descriptors,
        // `attr` has the exact C layout required by
        // `landlock_path_beneath_attr`, and Landlock requires flags 0.
        let result = unsafe {
            libc::syscall(
                libc::SYS_landlock_add_rule,
                ruleset_fd.as_raw_fd(),
                LANDLOCK_RULE_PATH_BENEATH,
                &attr as *const LandlockPathBeneathAttr,
                0 as libc::c_uint,
            )
        };
        if result != 0 {
            let error = std::io::Error::last_os_error();
            eprintln!(
                "failed to add Termux Landlock read rule for {} using ABI {effective_abi} and mask {allowed_access:#x}: {error}",
                path.display()
            );
            return Err(error.into());
        }
        added_rules += 1;
    }

    if added_rules == 0 {
        return Err(CodexErr::Sandbox(SandboxErr::LandlockRestrict));
    }

    set_no_new_privs()?;
    // SAFETY: `ruleset_fd` is a live Landlock ruleset descriptor and
    // the kernel API currently requires flags 0.
    let result = unsafe {
        libc::syscall(
            libc::SYS_landlock_restrict_self,
            ruleset_fd.as_raw_fd(),
            0 as libc::c_uint,
        )
    };
    if result != 0 {
        let error = std::io::Error::last_os_error();
        eprintln!("failed to restrict the Termux process with Landlock ABI {effective_abi}: {error}");
        return Err(error.into());
    }

    Ok(())
}

fn current_landlock_abi(maximum_abi: ABI) -> std::io::Result<ABI> {
    // SAFETY: querying the supported Landlock ABI requires a null attribute,
    // size 0, and LANDLOCK_CREATE_RULESET_VERSION as the sole flag.
    let result = unsafe {
        libc::syscall(
            libc::SYS_landlock_create_ruleset,
            std::ptr::null::<libc::c_void>(),
            0usize,
            LANDLOCK_CREATE_RULESET_VERSION,
        )
    };
    if result < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(std::cmp::min(maximum_abi, ABI::from(result as i32)))
}

fn termux_read_access_mask(requested_abi: ABI, kernel_abi: ABI) -> u64 {
    AccessFs::from_read(std::cmp::min(requested_abi, kernel_abi)).bits()
}

/// Android SELinux intentionally denies opening `/`, even though an app may
/// open selected descendants. Landlock needs an open path file descriptor for
/// every allow rule, so a single `/` rule is silently unusable in Termux. Use a
/// fail-closed list of Android/Termux hierarchies instead: unavailable entries
/// are ignored by the Landlock crate's best-effort compatibility layer, while
/// omitted paths remain inaccessible after restriction.
fn legacy_readable_roots() -> Vec<PathBuf> {
    let prefix = std::env::var_os("PREFIX").map(PathBuf::from);
    legacy_readable_roots_for_prefix(prefix.as_deref())
}

fn is_termux_environment() -> bool {
    std::env::var_os("PREFIX")
        .as_deref()
        .is_some_and(|prefix| is_termux_prefix(Path::new(prefix)))
}

fn open_path_for_landlock(path: &Path) -> std::io::Result<OwnedFd> {
    let path = CString::new(path.as_os_str().as_bytes()).map_err(|_| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "Landlock path contains an interior NUL byte",
        )
    })?;
    // SAFETY: `path` is a live NUL-terminated CString and the flags do not
    // require a mode argument.
    let fd = unsafe { libc::open(path.as_ptr(), libc::O_PATH | libc::O_CLOEXEC) };
    if fd < 0 {
        Err(std::io::Error::last_os_error())
    } else {
        // SAFETY: a successful open returned a new descriptor whose ownership
        // is transferred exactly once to this OwnedFd.
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    }
}

fn legacy_readable_roots_for_prefix(prefix: Option<&Path>) -> Vec<PathBuf> {
    let Some(prefix) = prefix.filter(|path| is_termux_prefix(path)) else {
        return vec![PathBuf::from("/")];
    };

    let mut roots = BTreeSet::from([
        PathBuf::from("/apex"),
        PathBuf::from("/dev"),
        PathBuf::from("/linkerconfig"),
        PathBuf::from("/mnt"),
        PathBuf::from("/odm"),
        PathBuf::from("/odm_dlkm"),
        PathBuf::from("/proc"),
        PathBuf::from("/product"),
        PathBuf::from("/storage"),
        PathBuf::from("/sys"),
        PathBuf::from("/system"),
        PathBuf::from("/system_ext"),
        PathBuf::from("/vendor"),
        PathBuf::from("/vendor_dlkm"),
    ]);
    // PREFIX is normally <app-data>/files/usr. Its parent includes both the
    // Termux package tree and HOME without granting other apps' private data.
    if let Some(termux_files) = prefix.parent() {
        roots.insert(termux_files.to_path_buf());
    } else {
        roots.insert(prefix.to_path_buf());
    }
    roots.into_iter().collect()
}

pub(crate) fn is_termux_prefix(path: &Path) -> bool {
    path.ends_with("com.termux/files/usr")
}

/// Installs a seccomp filter for Linux network sandboxing.
///
/// The filter is applied to the current thread so only the sandboxed child
/// inherits it.
fn install_network_seccomp_filter_on_current_thread(
    mode: NetworkSeccompMode,
) -> std::result::Result<(), SandboxErr> {
    fn deny_syscall(rules: &mut BTreeMap<i64, Vec<SeccompRule>>, nr: i64) {
        rules.insert(nr, vec![]); // empty rule vec = unconditional match
    }

    // Build rule map.
    let mut rules: BTreeMap<i64, Vec<SeccompRule>> = BTreeMap::new();

    deny_syscall(&mut rules, libc::SYS_ptrace);
    deny_syscall(&mut rules, libc::SYS_process_vm_readv);
    deny_syscall(&mut rules, libc::SYS_process_vm_writev);
    deny_syscall(&mut rules, libc::SYS_io_uring_setup);
    deny_syscall(&mut rules, libc::SYS_io_uring_enter);
    deny_syscall(&mut rules, libc::SYS_io_uring_register);

    match mode {
        NetworkSeccompMode::Restricted => {
            deny_syscall(&mut rules, libc::SYS_connect);
            deny_syscall(&mut rules, libc::SYS_accept);
            deny_syscall(&mut rules, libc::SYS_accept4);
            deny_syscall(&mut rules, libc::SYS_bind);
            deny_syscall(&mut rules, libc::SYS_listen);
            deny_syscall(&mut rules, libc::SYS_getpeername);
            deny_syscall(&mut rules, libc::SYS_getsockname);
            deny_syscall(&mut rules, libc::SYS_shutdown);
            deny_syscall(&mut rules, libc::SYS_sendto);
            deny_syscall(&mut rules, libc::SYS_sendmmsg);
            // NOTE: allowing recvfrom allows some tools like: `cargo clippy`
            // to run with their socketpair + child processes for sub-proc
            // management.
            // deny_syscall(&mut rules, libc::SYS_recvfrom);
            deny_syscall(&mut rules, libc::SYS_recvmmsg);
            deny_syscall(&mut rules, libc::SYS_getsockopt);
            deny_syscall(&mut rules, libc::SYS_setsockopt);

            // For `socket` we allow AF_UNIX (arg0 == AF_UNIX) and deny
            // everything else.
            let unix_only_rule = SeccompRule::new(vec![SeccompCondition::new(
                0, // first argument (domain)
                SeccompCmpArgLen::Dword,
                SeccompCmpOp::Ne,
                libc::AF_UNIX as u64,
            )?])?;

            rules.insert(libc::SYS_socket, vec![unix_only_rule.clone()]);
            rules.insert(libc::SYS_socketpair, vec![unix_only_rule]);
        }
        NetworkSeccompMode::ProxyRouted => {
            // In proxy-routed mode we allow IP sockets in the isolated
            // namespace (used to reach the local TCP bridge) but deny socket()
            // for all other families, including AF_UNIX. Only AF_UNIX
            // socketpair() remains available for process-local IPC because it
            // cannot connect to a socket outside the sandbox or bypass the
            // bridge.
            let deny_non_ip_socket = SeccompRule::new(vec![
                SeccompCondition::new(
                    0,
                    SeccompCmpArgLen::Dword,
                    SeccompCmpOp::Ne,
                    libc::AF_INET as u64,
                )?,
                SeccompCondition::new(
                    0,
                    SeccompCmpArgLen::Dword,
                    SeccompCmpOp::Ne,
                    libc::AF_INET6 as u64,
                )?,
            ])?;
            let deny_non_unix_socketpair = SeccompRule::new(vec![SeccompCondition::new(
                0,
                SeccompCmpArgLen::Dword,
                SeccompCmpOp::Ne,
                libc::AF_UNIX as u64,
            )?])?;
            rules.insert(libc::SYS_socket, vec![deny_non_ip_socket]);
            rules.insert(libc::SYS_socketpair, vec![deny_non_unix_socketpair]);
        }
    }

    let filter = SeccompFilter::new(
        rules,
        SeccompAction::Allow,                     // default – allow
        SeccompAction::Errno(libc::EPERM as u32), // when rule matches – return EPERM
        if cfg!(target_arch = "x86_64") {
            TargetArch::x86_64
        } else if cfg!(target_arch = "aarch64") {
            TargetArch::aarch64
        } else {
            unimplemented!("unsupported architecture for seccomp filter");
        },
    )?;

    let prog: BpfProgram = filter.try_into()?;

    apply_filter(&prog)?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::NetworkSeccompMode;
    use super::is_termux_prefix;
    use super::legacy_readable_roots_for_prefix;
    use super::network_seccomp_mode;
    use super::open_path_for_landlock;
    use super::should_install_network_seccomp;
    use super::termux_read_access_mask;
    use codex_protocol::protocol::NetworkSandboxPolicy;
    use landlock::ABI;
    use landlock::Access;
    use landlock::AccessFs;
    use std::os::fd::AsRawFd;
    use std::path::Path;
    use std::path::PathBuf;

    #[test]
    fn termux_legacy_roots_do_not_depend_on_opening_android_root() {
        let prefix = Path::new("/data/data/com.termux/files/usr");
        let roots = legacy_readable_roots_for_prefix(Some(prefix));
        assert!(!roots.contains(&PathBuf::from("/")));
        assert!(roots.contains(&PathBuf::from("/data/data/com.termux/files")));
        assert!(roots.contains(&PathBuf::from("/system")));
        assert!(roots.contains(&PathBuf::from("/apex")));
    }

    #[test]
    fn ordinary_linux_legacy_root_remains_unchanged() {
        assert_eq!(
            legacy_readable_roots_for_prefix(Some(Path::new("/usr"))),
            vec![PathBuf::from("/")]
        );
        assert!(is_termux_prefix(Path::new(
            "/data/data/com.termux/files/usr"
        )));
    }

    #[test]
    fn termux_landlock_path_is_opened_with_o_path() {
        let fd = open_path_for_landlock(Path::new("/"))
            .expect("opening the filesystem root with O_PATH should succeed");
        let flags = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFL) };
        assert_ne!(flags, -1);
        assert_eq!(flags & libc::O_PATH, libc::O_PATH);
    }

    #[test]
    fn termux_read_mask_is_limited_to_the_running_kernel_abi() {
        assert_eq!(
            termux_read_access_mask(ABI::V5, ABI::V3),
            AccessFs::from_read(ABI::V3).bits()
        );
        assert_eq!(
            termux_read_access_mask(ABI::V3, ABI::V5),
            AccessFs::from_read(ABI::V3).bits()
        );
    }
    use pretty_assertions::assert_eq;

    #[test]
    fn managed_network_enforces_seccomp_even_for_full_network_policy() {
        assert_eq!(
            should_install_network_seccomp(
                NetworkSandboxPolicy::Enabled,
                /*allow_network_for_proxy*/ true,
            ),
            true
        );
    }

    #[test]
    fn full_network_policy_without_managed_network_skips_seccomp() {
        assert_eq!(
            should_install_network_seccomp(
                NetworkSandboxPolicy::Enabled,
                /*allow_network_for_proxy*/ false,
            ),
            false
        );
    }

    #[test]
    fn restricted_network_policy_always_installs_seccomp() {
        assert!(should_install_network_seccomp(
            NetworkSandboxPolicy::Restricted,
            /*allow_network_for_proxy*/ false,
        ));
        assert!(should_install_network_seccomp(
            NetworkSandboxPolicy::Restricted,
            /*allow_network_for_proxy*/ true,
        ));
    }

    #[test]
    fn managed_proxy_routes_use_proxy_routed_seccomp_mode() {
        assert_eq!(
            network_seccomp_mode(
                NetworkSandboxPolicy::Enabled,
                /*allow_network_for_proxy*/ true,
                /*proxy_routed_network*/ true,
            ),
            Some(NetworkSeccompMode::ProxyRouted)
        );
    }

    #[test]
    fn restricted_network_without_proxy_routing_uses_restricted_mode() {
        assert_eq!(
            network_seccomp_mode(
                NetworkSandboxPolicy::Restricted,
                /*allow_network_for_proxy*/ false,
                /*proxy_routed_network*/ false,
            ),
            Some(NetworkSeccompMode::Restricted)
        );
    }

    #[test]
    fn full_network_without_managed_proxy_skips_network_seccomp_mode() {
        assert_eq!(
            network_seccomp_mode(
                NetworkSandboxPolicy::Enabled,
                /*allow_network_for_proxy*/ false,
                /*proxy_routed_network*/ false,
            ),
            None
        );
    }
}
