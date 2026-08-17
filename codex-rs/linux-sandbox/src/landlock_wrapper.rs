//! Compatibility wrapper around the legacy Landlock backend.
//!
//! Android app processes can receive `ENOSYS` for Landlock because the zygote
//! seccomp policy hides those syscalls. In Termux only, preserve the existing
//! fail-closed read-only downgrade by stacking a filesystem seccomp filter.

use std::error::Error;
use std::path::Path;

use codex_protocol::error::CodexErr;
use codex_protocol::error::CodexErrorDetails;
use codex_protocol::error::Result;
use codex_protocol::models::PermissionProfile;

#[path = "landlock.rs"]
mod original;
#[path = "termux_read_only_seccomp.rs"]
mod termux_read_only_seccomp;

pub(crate) use original::is_termux_prefix;

pub(crate) fn apply_permission_profile_to_current_thread(
    permission_profile: &PermissionProfile,
    cwd: &Path,
    apply_landlock_fs: bool,
    allow_network_for_proxy: bool,
    proxy_routed_network: bool,
) -> Result<()> {
    match original::apply_permission_profile_to_current_thread(
        permission_profile,
        cwd,
        apply_landlock_fs,
        allow_network_for_proxy,
        proxy_routed_network,
    ) {
        Err(error)
            if apply_landlock_fs
                && is_termux_environment()
                && error_contains_errno(&error, libc::ENOSYS) =>
        {
            eprintln!(
                "codex-linux-sandbox: Android hid Landlock from the Termux app; enforcing the fail-closed global read-only filesystem policy with seccomp"
            );
            termux_read_only_seccomp::install_on_current_thread()?;
            Ok(())
        }
        result => result,
    }
}

fn is_termux_environment() -> bool {
    std::env::var_os("PREFIX")
        .as_deref()
        .is_some_and(|prefix| is_termux_prefix(Path::new(prefix)))
}

fn error_contains_errno(error: &CodexErr, expected: i32) -> bool {
    // CodexErrorDetails::Io is transparent. Its Error::source() delegates to
    // io::Error::source(), which is usually None for raw OS errors, so inspect
    // the direct payload before walking any nested source chain.
    if matches!(
        error.details(),
        CodexErrorDetails::Io(io_error)
            if io_error.raw_os_error() == Some(expected)
    ) {
        return true;
    }

    let mut current = error.source();
    while let Some(source) = current {
        if source
            .downcast_ref::<std::io::Error>()
            .is_some_and(|io_error| io_error.raw_os_error() == Some(expected))
        {
            return true;
        }
        current = source.source();
    }
    false
}

#[cfg(test)]
mod tests {
    use super::error_contains_errno;
    use codex_protocol::error::CodexErr;

    #[test]
    fn finds_nested_enosys_io_error() {
        let error = CodexErr::from(std::io::Error::from_raw_os_error(libc::ENOSYS));
        assert!(error_contains_errno(&error, libc::ENOSYS));
        assert!(!error_contains_errno(&error, libc::EPERM));
    }
}
