use super::*;
use pretty_assertions::assert_eq;

#[test]
fn records_keep_recent_failures_and_select_the_requested_tree() {
    let mut records = ReviewRecords::default();
    let root = ThreadId::new();
    let child = ThreadId::new();
    let unrelated = ThreadId::new();
    records.push(child, br#"{"child":"denied"}"#.to_vec());
    records.push(unrelated, br#"{"unrelated":"denied"}"#.to_vec());
    for index in 0..12 {
        records.push(root, format!(r#"{{"root":{index}}}"#).into_bytes());
    }
    let attachment = records
        .attachment(&[root, child])
        .expect("task-tree records");
    let expected = std::iter::once("{\"child\":\"denied\"}\n".to_string())
        .chain((4..12).map(|index| format!("{{\"root\":{index}}}\n")))
        .collect::<String>();
    assert_eq!(attachment.buffer, expected.into_bytes());
}

#[test]
fn record_count_and_bytes_are_bounded_across_threads() {
    let mut records = ReviewRecords::default();
    for _ in 0..MAX_RECORDS + 1 {
        records.push(ThreadId::new(), b"{}".to_vec());
    }
    assert_eq!(records.records.len(), MAX_RECORDS);
    let payload = vec![b' '; MAX_BYTES / 3];
    let thread_id = ThreadId::new();
    for _ in 0..4 {
        records.push(thread_id, payload.clone());
    }
    assert!(records.bytes <= MAX_BYTES);
    assert_eq!(records.records.len(), 2);
    assert_eq!(
        records
            .attachment(&[thread_id])
            .expect("bounded records")
            .buffer
            .len(),
        2 * (payload.len() + 1)
    );
}
