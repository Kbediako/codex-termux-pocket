//! Fail-closed filesystem fallback for Android/Termux app processes.
//!
//! Android's zygote seccomp policy can hide the Landlock syscalls from apps,
//! even when the underlying kernel has Landlock enabled. In that environment
//! the legacy path-based backend cannot start. Termux already downgrades
//! policies that need path-sensitive write carve-outs to a global read-only
//! profile, so a seccomp filter can enforce that reduced policy without ever
//! running the requested command unrestricted.

use std::collections::BTreeMap;

use codex_protocol::error::SandboxErr;
use seccompiler::BpfProgram;
use seccompiler::SeccompAction;
use seccompiler::SeccompCmpArgLen;
use seccompiler::SeccompCmpOp;
use seccompiler::SeccompCondition;
use seccompiler::SeccompFilter;
use seccompiler::SeccompRule;
use seccompiler::TargetArch;
use seccompiler::apply_filter;

type RuleMap = BTreeMap<i64, Vec<SeccompRule>>;

pub(super) fn install_on_current_thread() -> std::result::Result<(), SandboxErr> {
    let filter = build_filter()?;
    let program: BpfProgram = filter.try_into()?;
    apply_filter(&program)?;
    Ok(())
}

fn build_filter() -> std::result::Result<SeccompFilter, SandboxErr> {
    Ok(SeccompFilter::new(
        read_only_rules()?,
        SeccompAction::Allow,
        SeccompAction::Errno(libc::EROFS as u32),
        target_arch(),
    )?)
}

fn read_only_rules() -> std::result::Result<RuleMap, SandboxErr> {
    let mut rules = RuleMap::new();

    // Block every normal way to obtain a new writable filesystem descriptor.
    rules.insert(libc::SYS_openat, write_open_rules(2)?);
    rules.insert(libc::SYS_openat2, vec![]);
    rules.insert(libc::SYS_open_by_handle_at, write_open_rules(2)?);
    rules.insert(libc::SYS_mq_open, write_open_rules(1)?);

    #[cfg(target_arch = "x86_64")]
    {
        rules.insert(libc::SYS_open, write_open_rules(1)?);
        deny(&mut rules, libc::SYS_creat);
    }

    // These syscalls mutate namespace entries, file contents, ownership,
    // permissions, timestamps, extended attributes, mounts, or quota state.
    for syscall in [
        libc::SYS_truncate,
        libc::SYS_ftruncate,
        libc::SYS_fallocate,
        libc::SYS_mknodat,
        libc::SYS_mkdirat,
        libc::SYS_unlinkat,
        libc::SYS_symlinkat,
        libc::SYS_linkat,
        libc::SYS_renameat,
        libc::SYS_renameat2,
        libc::SYS_fchmod,
        libc::SYS_fchmodat,
        libc::SYS_fchown,
        libc::SYS_fchownat,
        libc::SYS_setxattr,
        libc::SYS_lsetxattr,
        libc::SYS_fsetxattr,
        libc::SYS_removexattr,
        libc::SYS_lremovexattr,
        libc::SYS_fremovexattr,
        libc::SYS_utimensat,
        libc::SYS_mount,
        libc::SYS_umount2,
        libc::SYS_pivot_root,
        libc::SYS_open_tree,
        libc::SYS_move_mount,
        libc::SYS_fsopen,
        libc::SYS_fsconfig,
        libc::SYS_fsmount,
        libc::SYS_fspick,
        libc::SYS_mount_setattr,
        libc::SYS_quotactl,
        libc::SYS_quotactl_fd,
        libc::SYS_mq_unlink,
        // AF_UNIX bind() can create a filesystem entry. Denying bind is more
        // restrictive than Landlock for IP sockets, but preserves read-only
        // filesystem semantics when the network profile itself is permissive.
        libc::SYS_bind,
        // io_uring can submit open/write operations that are not individually
        // evaluated by a classic seccomp filter.
        libc::SYS_io_uring_setup,
        libc::SYS_io_uring_enter,
        libc::SYS_io_uring_register,
        // Do not let a sandboxed process acquire a writable descriptor from a
        // less-restricted process and then bypass the open rules above.
        libc::SYS_ptrace,
        libc::SYS_process_vm_writev,
        libc::SYS_pidfd_getfd,
    ] {
        deny(&mut rules, syscall);
    }

    #[cfg(target_arch = "x86_64")]
    for syscall in [
        libc::SYS_unlink,
        libc::SYS_rename,
        libc::SYS_mkdir,
        libc::SYS_rmdir,
        libc::SYS_link,
        libc::SYS_symlink,
        libc::SYS_mknod,
        libc::SYS_chmod,
        libc::SYS_chown,
        libc::SYS_lchown,
        libc::SYS_utime,
        libc::SYS_utimes,
        libc::SYS_futimesat,
    ] {
        deny(&mut rules, syscall);
    }

    Ok(rules)
}

fn write_open_rules(flags_argument: u8) -> std::result::Result<Vec<SeccompRule>, SandboxErr> {
    // Access mode is a two-bit field, while create/truncate/append are
    // independent bits. Separate rules provide OR semantics across them.
    [
        (libc::O_ACCMODE, libc::O_WRONLY),
        (libc::O_ACCMODE, libc::O_RDWR),
        (libc::O_CREAT, libc::O_CREAT),
        (libc::O_TRUNC, libc::O_TRUNC),
        (libc::O_APPEND, libc::O_APPEND),
    ]
    .into_iter()
    .map(|(mask, value)| {
        Ok(SeccompRule::new(vec![SeccompCondition::new(
            flags_argument,
            SeccompCmpArgLen::Dword,
            SeccompCmpOp::MaskedEq(mask as u64),
            value as u64,
        )?])?)
    })
    .collect()
}

fn deny(rules: &mut RuleMap, syscall: i64) {
    // An empty rule vector is an unconditional match in seccompiler.
    rules.insert(syscall, vec![]);
}

#[cfg(target_arch = "x86_64")]
fn target_arch() -> TargetArch {
    TargetArch::x86_64
}

#[cfg(target_arch = "aarch64")]
fn target_arch() -> TargetArch {
    TargetArch::aarch64
}

#[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
compile_error!("the Termux read-only seccomp fallback supports only x86_64 and aarch64");

#[cfg(test)]
mod tests {
    use super::build_filter;
    use super::read_only_rules;

    #[test]
    fn filter_compiles_to_bpf() {
        let filter = build_filter().expect("read-only filter should be valid");
        let _: seccompiler::BpfProgram = filter
            .try_into()
            .expect("read-only filter should compile to BPF");
    }

    #[test]
    fn openat_rejects_each_write_capability() {
        let rules = read_only_rules().expect("read-only rules should be valid");
        assert_eq!(rules[&libc::SYS_openat].len(), 5);
        assert!(rules[&libc::SYS_openat2].is_empty());
        assert!(rules[&libc::SYS_unlinkat].is_empty());
        assert!(rules[&libc::SYS_io_uring_setup].is_empty());
    }

    #[cfg(target_arch = "x86_64")]
    #[test]
    fn legacy_x86_64_mutation_syscalls_are_covered() {
        let rules = read_only_rules().expect("read-only rules should be valid");
        assert_eq!(rules[&libc::SYS_open].len(), 5);
        assert!(rules[&libc::SYS_creat].is_empty());
        assert!(rules[&libc::SYS_rename].is_empty());
    }
}
