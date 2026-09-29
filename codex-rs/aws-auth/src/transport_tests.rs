//! Regression coverage for the HTTP-body bridge used by AWS credential responses.

use std::collections::VecDeque;
use std::future::poll_fn;
use std::io;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;

use super::*;
use http_body::Body;
use http_body::Frame;
use pretty_assertions::assert_eq;

#[derive(Default)]
struct TestBody {
    frames: VecDeque<Result<Frame<Bytes>, io::Error>>,
    yield_once: bool,
    pending_forever: bool,
    dropped: Option<Arc<AtomicBool>>,
}

impl Body for TestBody {
    type Data = Bytes;
    type Error = io::Error;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, io::Error>>> {
        if self.pending_forever {
            return Poll::Pending;
        }
        if self.yield_once {
            self.yield_once = false;
            cx.waker().wake_by_ref();
            return Poll::Pending;
        }
        Poll::Ready(self.frames.pop_front())
    }
}

impl Drop for TestBody {
    fn drop(&mut self) {
        if let Some(dropped) = &self.dropped {
            dropped.store(true, Ordering::SeqCst);
        }
    }
}

fn sdk_body(body: TestBody) -> SdkBody {
    SdkBody::from_body_1_x(SyncBody(Mutex::new(Box::pin(body))))
}

#[tokio::test]
async fn sdk_body_preserves_pending_chunks_trailers_and_eof() {
    let trailers = http::HeaderMap::from_iter([(
        http::HeaderName::from_static("x-checksum"),
        http::HeaderValue::from_static("verified"),
    )]);
    let body = sdk_body(TestBody {
        frames: VecDeque::from([
            Ok(Frame::data(Bytes::from_static(b"first"))),
            Ok(Frame::data(Bytes::from_static(b"second"))),
            Ok(Frame::trailers(trailers.clone())),
        ]),
        yield_once: true,
        pending_forever: false,
        dropped: None,
    });
    let collected = body.collect().await.expect("collect the complete SDK body");
    assert_eq!(collected.trailers(), Some(&trailers));
    assert_eq!(collected.to_bytes(), Bytes::from_static(b"firstsecond"));
}

#[tokio::test]
async fn sdk_body_preserves_empty_bodies_and_errors() {
    let empty = sdk_body(TestBody::default())
        .collect()
        .await
        .expect("an empty SDK body should reach EOF");
    assert_eq!(empty.to_bytes(), Bytes::new());

    let body = sdk_body(TestBody {
        frames: VecDeque::from([
            Ok(Frame::data(Bytes::from_static(b"partial"))),
            Err(io::Error::other("credential response interrupted")),
        ]),
        yield_once: false,
        pending_forever: false,
        dropped: None,
    });
    let error = body
        .collect()
        .await
        .expect_err("a body error must propagate");
    assert_eq!(error.to_string(), "credential response interrupted");
}

#[tokio::test]
async fn dropping_pending_sdk_body_releases_the_inner_response() {
    let dropped = Arc::new(AtomicBool::new(false));
    let mut body = sdk_body(TestBody {
        frames: VecDeque::new(),
        yield_once: false,
        pending_forever: true,
        dropped: Some(Arc::clone(&dropped)),
    });
    poll_fn(|cx| {
        assert!(Pin::new(&mut body).poll_frame(cx).is_pending());
        Poll::Ready(())
    })
    .await;
    assert!(!dropped.load(Ordering::SeqCst));
    drop(body);
    assert!(dropped.load(Ordering::SeqCst));
}
