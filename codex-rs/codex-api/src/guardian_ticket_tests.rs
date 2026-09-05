use super::*;
use crate::common::ResponseEvent;
use crate::sse::responses::ResponsesStreamEvent;
use crate::sse::responses::process_responses_event;
use pretty_assertions::assert_eq;
use serde_json::json;

#[test]
fn response_created_receipt_is_runtime_only_and_redacted() {
    let raw = "a".repeat(43);
    let event: ResponsesStreamEvent = serde_json::from_value(json!({
        "type": "response.created",
        "response": {"id": "resp-1", "headers": {"x-codex-guardian-ticket": raw}}
    }))
    .unwrap();
    let ResponseEvent::Created { guardian_ticket } =
        process_responses_event(event).unwrap().unwrap()
    else {
        panic!("expected response.created");
    };
    let ticket = guardian_ticket.unwrap();
    assert_eq!(ticket.as_str(), raw);
    assert!(!format!("{ticket:?}").contains(&raw));
    let mut metadata = Some(HashMap::from([("turn_id".into(), "turn-1".into())]));
    attach(&mut metadata, Some(&ticket), ResponsesEndpoint::Guardian);
    assert_eq!(
        metadata,
        Some(HashMap::from([
            ("turn_id".into(), "turn-1".into()),
            (GUARDIAN_TICKET_METADATA_KEY.into(), raw),
        ]))
    );
    attach(
        &mut metadata,
        /*ticket*/ None,
        ResponsesEndpoint::Guardian,
    );
    assert_eq!(
        metadata,
        Some(HashMap::from([("turn_id".into(), "turn-1".into())]))
    );
}

#[test]
fn missing_or_malformed_response_receipts_do_not_become_tickets() {
    for response in [
        json!({}),
        json!({"headers": {"x-codex-guardian-ticket": "invalid"}}),
    ] {
        let event =
            serde_json::from_value(json!({"type": "response.created", "response": response}))
                .unwrap();
        assert!(matches!(
            process_responses_event(event).unwrap(),
            Some(ResponseEvent::Created {
                guardian_ticket: None
            })
        ));
    }
}
