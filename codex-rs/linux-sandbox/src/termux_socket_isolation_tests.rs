use super::install_on_current_thread;
use pretty_assertions::assert_eq;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixListener;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::process::Command;
use std::process::Stdio;

const CHILD_TEST: &str = "termux_socket_isolation::tests::isolated_child";
const ROLE: &str = "CODEX_TERMUX_SOCKET_TEST_ROLE";

#[test]
fn socket_isolation_survives_exec_and_discards_inherited_sockets() {
    let root = tempfile::tempdir().expect("temporary directory");
    let socket = root.path().join("daemon.sock");
    let alias = root.path().join("alias.sock");
    let _listener = UnixListener::bind(&socket).expect("host listener");
    std::os::unix::fs::symlink(&socket, &alias).expect("socket alias");
    let inherited = UnixStream::connect(&alias).expect("host can connect");
    let fd = inherited.as_raw_fd();
    let mut child = Command::new(std::env::current_exe().expect("test executable"));
    child
        .args(["--exact", CHILD_TEST, "--nocapture", "--test-threads=1"])
        .env(ROLE, "execute")
        .env("CODEX_TERMUX_SOCKET_TEST_PATH", &socket)
        .env("CODEX_TERMUX_SOCKET_TEST_ALIAS", &alias);
    // SAFETY: dup2 is async-signal-safe; inherited remains alive until output
    // returns. A high descriptor avoids the child's standard stream setup.
    unsafe {
        child.pre_exec(move || {
            if libc::dup2(fd, 200) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let output = child.output().expect("run isolated child");
    assert_eq!(output.status.code(), Some(0), "{output:?}");
    assert!(String::from_utf8_lossy(&output.stdout).contains("socket-isolation-ok"));
}

#[test]
fn socket_backed_standard_output_is_rejected() {
    let (socket, _peer) = UnixStream::pair().expect("stdio socket pair");
    let output = Command::new(std::env::current_exe().expect("test executable"))
        .args(["--exact", CHILD_TEST, "--nocapture", "--test-threads=1"])
        .env(ROLE, "reject-stdio")
        .stdout(Stdio::from(std::os::fd::OwnedFd::from(socket)))
        .output()
        .expect("run stdio rejection child");
    assert_eq!(output.status.code(), Some(0), "{output:?}");
    assert!(String::from_utf8_lossy(&output.stderr).contains("socket-backed stdio rejected"));
}

// Seccomp is irreversible, so only a disposable child test process installs
// the filter. The parent tests require explicit proof that this branch ran.
#[test]
fn isolated_child() {
    match std::env::var(ROLE).as_deref() {
        Ok("reject-stdio") => {
            let error = install_on_current_thread().expect_err("socket stdout must fail");
            assert!(error.to_string().contains("socket-backed stdio"));
            eprintln!("socket-backed stdio rejected");
        }
        Ok("execute") => {
            install_on_current_thread().expect("install socket isolation");
            let script = r#"
import errno, os, socket
try:
    os.fstat(200)
except OSError as error:
    assert error.errno == errno.EBADF, error
else:
    raise AssertionError('inherited socket survived exec')
for path in [os.environ['CODEX_TERMUX_SOCKET_TEST_PATH'],
             os.environ['CODEX_TERMUX_SOCKET_TEST_ALIAS'], '\0termux-daemon-probe']:
    try:
        socket.socket(socket.AF_UNIX).connect(path)
    except OSError as error:
        assert error.errno == errno.EPERM, error
    else:
        raise AssertionError('Unix socket access was allowed')
for family in [socket.AF_INET, socket.AF_INET6]:
    try:
        socket.socket(family)
    except OSError as error:
        assert error.errno == errno.EPERM, error
    else:
        raise AssertionError('network socket was allowed')
try:
    socket.socketpair()
except OSError as error:
    assert error.errno == errno.EPERM, error
else:
    raise AssertionError('socketpair was allowed')
read_fd, write_fd = os.pipe()
os.write(write_fd, b'pipe-ok')
assert os.read(read_fd, 7) == b'pipe-ok'
os.close(read_fd)
os.close(write_fd)
with open('/proc/self/status') as status:
    assert 'NoNewPrivs:\t1' in status.read()
print('socket-isolation-ok')
"#;
            let error = Command::new("python3").args(["-c", script]).exec();
            panic!("execute socket probe: {error}");
        }
        _ => {}
    }
}
