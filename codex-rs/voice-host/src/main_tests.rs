//! Verify the real parent-loss watchdog while the startup worker is deterministically blocked.

use super::*;
use std::process::Stdio;

use pretty_assertions::assert_eq;
use tokio::io::AsyncReadExt;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;
use tokio::time::timeout;

const STARTUP_BLOCKED: &[u8] = b"voice startup blocked\n";
const CHILD_ENV: &str = "CODEX_VOICE_WATCHDOG_TEST_CHILD";

#[test]
#[ignore = "subprocess fixture for the parent-loss watchdog test"]
fn blocked_startup_fixture() {
    if std::env::var_os(CHILD_ENV).as_deref() != Some(std::ffi::OsStr::new("1")) {
        return;
    }
    run(|_| {
        io::stderr().write_all(STARTUP_BLOCKED)?;
        io::stderr().flush()?;
        loop {
            std::thread::park();
        }
    })
    .unwrap();
}

#[tokio::test]
async fn parent_pipe_loss_terminates_helper_with_blocked_transport_startup() {
    timeout(Duration::from_secs(/*secs*/ 10), async {
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "tests::blocked_startup_fixture",
                "--ignored",
                "--nocapture",
            ])
            .env(CHILD_ENV, "1")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let mut input = child.stdin.take().unwrap();
        input
            .write_all(
                &encode_frame(&Message::Hello {
                    protocol: 1,
                    build_commit: BUILD_COMMIT.to_owned(),
                })
                .unwrap(),
            )
            .await
            .unwrap();
        let expected = encode_frame(&Message::Ready {}).unwrap();
        let mut prefix = Vec::new();
        // libtest writes a short harness prefix before the helper's framed output.
        while !prefix.ends_with(&expected) {
            assert!(prefix.len() < 512, "missing helper ready frame");
            prefix.push(child.stdout.as_mut().unwrap().read_u8().await.unwrap());
        }
        input
            .write_all(&encode_frame(&Message::StartTransport {}).unwrap())
            .await
            .unwrap();
        let mut marker = vec![0; STARTUP_BLOCKED.len()];
        child
            .stderr
            .as_mut()
            .unwrap()
            .read_exact(&mut marker)
            .await
            .unwrap();
        assert_eq!(marker, STARTUP_BLOCKED);
        assert!(child.try_wait().unwrap().is_none());
        drop(input);
        let output = child.wait_with_output().await.unwrap();
        assert_eq!(output.status.code(), Some(1));
        assert_eq!((output.stdout, output.stderr), (vec![], vec![]));
    })
    .await
    .unwrap();
}
