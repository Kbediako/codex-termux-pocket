//! Additional socket isolation for the Termux global read-only backend.
//!
//! A path-based Landlock rule cannot hide the privileged app-server socket.
//! This backend therefore permits no sockets, including inherited ones. It is
//! installed by the single-threaded sandbox helper before command execution;
//! the existing filesystem and network restrictions are still mandatory.

use std::collections::BTreeMap;
use std::io;

use codex_protocol::error::SandboxErr;
use seccompiler::BpfProgram;
use seccompiler::SeccompAction;
use seccompiler::SeccompFilter;
use seccompiler::SeccompRule;
use seccompiler::TargetArch;
use seccompiler::apply_filter;

pub(crate) fn install_on_current_thread() -> codex_protocol::error::Result<()> {
    // SAFETY: PR_SET_NO_NEW_PRIVS takes only integer arguments.
    if unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) } != 0 {
        return Err(io::Error::last_os_error().into());
    }
    protect_inherited_descriptors()?;
    install_socket_filter()?;
    Ok(())
}

fn protect_inherited_descriptors() -> io::Result<()> {
    for fd in 0..=2 {
        let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
        // SAFETY: stat points to writable storage and fstat checks the fd.
        if unsafe { libc::fstat(fd, stat.as_mut_ptr()) } < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::EBADF) {
                continue;
            }
            return Err(error);
        }
        // SAFETY: fstat initialized the complete structure on success.
        if unsafe { stat.assume_init() }.st_mode & libc::S_IFMT == libc::S_IFSOCK {
            return Err(io::Error::other(
                "Termux sandbox rejects socket-backed stdio",
            ));
        }
    }

    // Keep the directory handle alive while setting flags, so its own entry
    // cannot become an unrelated descriptor. There are no worker threads in
    // the sandbox helper, and subsequent Rust/landlock opens use CLOEXEC.
    let descriptors = std::fs::read_dir("/proc/self/fd")?;
    for entry in descriptors {
        let entry = entry?;
        let fd = entry
            .file_name()
            .to_str()
            .and_then(|name| name.parse::<libc::c_int>().ok())
            .ok_or_else(|| io::Error::other("invalid /proc/self/fd entry"))?;
        if fd < 3 {
            continue;
        }
        // SAFETY: F_SETFD only sets the close-on-exec flag on an existing fd.
        if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

fn install_socket_filter() -> std::result::Result<(), SandboxErr> {
    let mut rules = BTreeMap::<i64, Vec<SeccompRule>>::new();
    for syscall in [
        libc::SYS_socket,
        libc::SYS_socketpair,
        libc::SYS_connect,
        libc::SYS_accept,
        libc::SYS_accept4,
        libc::SYS_bind,
        libc::SYS_listen,
        libc::SYS_sendto,
        libc::SYS_sendmsg,
        libc::SYS_sendmmsg,
        libc::SYS_recvmsg,
        libc::SYS_recvmmsg,
        // Block indirect socket operations and acquisition of host fds.
        libc::SYS_io_uring_setup,
        libc::SYS_io_uring_enter,
        libc::SYS_io_uring_register,
        libc::SYS_pidfd_getfd,
        libc::SYS_ptrace,
        libc::SYS_process_vm_writev,
    ] {
        rules.insert(syscall, vec![]);
    }
    let arch = if cfg!(target_arch = "x86_64") {
        TargetArch::x86_64
    } else if cfg!(target_arch = "aarch64") {
        TargetArch::aarch64
    } else {
        unimplemented!("unsupported architecture for the Termux socket filter");
    };
    let program: BpfProgram = SeccompFilter::new(
        rules,
        SeccompAction::Allow,
        SeccompAction::Errno(libc::EPERM as u32),
        arch,
    )?
    .try_into()?;
    apply_filter(&program)?;
    Ok(())
}

#[cfg(test)]
#[path = "termux_socket_isolation_tests.rs"]
mod tests;
