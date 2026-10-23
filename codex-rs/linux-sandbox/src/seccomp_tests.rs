//! Verify network policies select the expected seccomp enforcement mode.

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
use pretty_assertions::assert_eq;
use std::os::fd::AsRawFd;
use std::path::Path;
use std::path::PathBuf;

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
